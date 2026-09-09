import Foundation

nonisolated struct OpenRouterClient: OpenRouterServing, DetailedTranscriptionServing {
    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let session: URLSession

    init(session: URLSession = OpenRouterClient.makeSession()) {
        self.session = session
    }

    init(configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = min(configuration.timeoutIntervalForRequest, 30)
        configuration.timeoutIntervalForResource = min(configuration.timeoutIntervalForResource, MeetingCompletionBudget.resourceTimeout)
        self.session = URLSession(
            configuration: configuration,
            delegate: OpenRouterNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func models() async throws -> [OpenRouterModel] {
        let textModels = try await fetchModels(outputModality: "text")
        let transcriptionModels = try await fetchModels(outputModality: "transcription")
        var seen = Set<String>()
        return (textModels + transcriptionModels).filter { seen.insert($0.id).inserted }
    }

    func validateKey(_ apiKey: String) async throws {
        let request = try makeRequest(path: "/key", method: "GET", apiKey: apiKey, timeout: 20)
        _ = try await data(for: request)
    }

    func transcribe(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?
    ) async throws -> AITextResponse {
        var body = TranscriptionRequest(
            model: model,
            inputAudio: InputAudio(data: audio.base64EncodedString(), format: format),
            language: language?.isEmpty == false ? language : nil
        )
        let request = try makeJSONRequest(
            path: "/audio/transcriptions",
            apiKey: apiKey,
            body: &body,
            timeout: 70
        )
        let data = try await data(for: request)
        let response = try decode(TranscriptionResponse.self, from: data)
        return AITextResponse(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            costUSD: response.usage?.cost
        )
    }

    func transcribeDetailed(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?,
        prompt: String?
    ) async throws -> DetailedTranscriptionResult {
        var body = DetailedTranscriptionRequest(
            model: model,
            inputAudio: InputAudio(data: audio.base64EncodedString(), format: format),
            language: language?.isEmpty == false ? language : nil,
            responseFormat: "verbose_json",
            timestampGranularities: ["segment", "word"],
            prompt: prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? prompt : nil
        )
        let request = try makeJSONRequest(
            path: "/audio/transcriptions",
            apiKey: apiKey,
            body: &body,
            timeout: 70
        )
        let data = try await data(for: request)
        return try decode(DetailedTranscriptionResponse.self, from: data).result()
    }

    func complete(
        system: String,
        user: String,
        model: String,
        apiKey: String,
        maxTokens: Int
    ) async throws -> AITextResponse {
        var body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user)
            ],
            maxTokens: max(1, maxTokens),
            stream: false,
            reasoning: OpenRouterModel.requiresReasoningBudget(for: model)
                ? ReasoningOptions(effort: "low", exclude: true) : nil
        )
        let request = try makeJSONRequest(path: "/chat/completions", apiKey: apiKey, body: &body,
            timeout: MeetingCompletionBudget.requestTimeout(outputTokens: maxTokens))
        let data = try await data(for: request)
        let response = try decode(ChatResponse.self, from: data)
        guard let choice = response.choices.first else {
            throw AIError(message: "모델 응답을 읽을 수 없어요. 잠시 후 다시 시도해 주세요.")
        }
        if choice.finishReason == "length" {
            throw AIError(message: "모델의 추론·답변이 출력 길이 제한에 도달했어요. 회의록이 완성되지 않았으니 다시 생성하거나 다른 모델을 선택해 주세요.")
        }
        if let error = choice.error { throw providerError(error) }
        if choice.finishReason == "error" {
            throw AIError(message: "모델 제공자가 답변 생성을 중단했어요. 잠시 후 다시 생성해 주세요.")
        }
        if choice.finishReason == "content_filter" || choice.message?.refusal?.isEmpty == false {
            throw AIError(message: "모델이 이 내용에 대한 회의록 생성을 거부했어요. 모델의 사용 정책과 녹음 내용을 확인해 주세요.")
        }
        let text = choice.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            // Reasoning is not a meeting report and must never be shown as one.
            throw AIError(message: "모델이 최종 답변을 반환하지 않았어요. 다시 생성하거나 다른 모델을 선택해 주세요.")
        }
        return AITextResponse(text: text, costUSD: response.usage?.cost)
    }

    nonisolated static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = MeetingCompletionBudget.resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: OpenRouterNoRedirectDelegate(), delegateQueue: nil)
    }

    private func fetchModels(outputModality: String) async throws -> [OpenRouterModel] {
        let request = try makeRequest(
            path: "/models",
            method: "GET",
            queryItems: [URLQueryItem(name: "output_modalities", value: outputModality)],
            timeout: 20
        )
        return try decode(ModelsResponse.self, from: try await data(for: request)).models
    }

    private func makeJSONRequest<T: Encodable>(
        path: String,
        apiKey: String,
        body: inout T,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: "POST", apiKey: apiKey, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        apiKey: String? = nil,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard path.hasPrefix("/") else { throw AIError(message: "OpenRouter 요청 경로가 올바르지 않아요.") }
        let url = Self.baseURL.appending(path: String(path.dropFirst()))
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AIError(message: "OpenRouter 요청 주소를 만들 수 없어요.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components.url,
              finalURL.scheme == "https",
              finalURL.host == "openrouter.ai" else {
            throw AIError(message: "OpenRouter 고정 주소만 사용할 수 있어요.")
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError(message: "OpenRouter 응답 형식이 올바르지 않아요.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw statusError(httpResponse.statusCode)
            }
            // Providers can report a generation failure after HTTP 200 was sent.
            // Decode only the safe numeric code, never relay their raw message.
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               let error = envelope.error {
                throw providerError(error)
            }
            return data
        } catch let error as AIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIError(message: "모델 응답 대기 시간이 초과됐어요. 저장된 전사문은 유지됩니다. 잠시 후 다시 생성하거나 더 빠른 모델을 선택해 주세요.")
        } catch {
            throw AIError(message: "OpenRouter에 연결할 수 없어요. 네트워크 연결을 확인해 주세요.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else { throw AIError(message: "OpenRouter 응답이 비어 있어요. 잠시 후 다시 시도해 주세요.") }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError(message: "OpenRouter 응답을 해석할 수 없어요. 모델 또는 서비스 상태를 확인해 주세요.")
        }
    }

    private func statusError(_ statusCode: Int) -> AIError {
        switch statusCode {
        case 300..<400:
            AIError(message: "OpenRouter 리디렉션 응답은 보안상 따르지 않았어요. 잠시 후 다시 시도해 주세요.")
        case 401:
            AIError(message: "OpenRouter API 키가 유효하지 않아요. 키를 다시 저장해 주세요.")
        case 402:
            AIError(message: "OpenRouter 크레딧이 부족해요. 결제 상태를 확인한 뒤 다시 시도해 주세요.")
        case 429:
            AIError(message: "OpenRouter 요청 한도를 초과했어요. 잠시 후 다시 시도해 주세요.")
        case 500..<600:
            AIError(message: "OpenRouter 서버 오류가 발생했어요. 잠시 후 다시 시도해 주세요.")
        default:
            AIError(message: "OpenRouter 요청이 실패했어요. 상태 코드 \(statusCode)를 확인해 주세요.")
        }
    }

    private func providerError(_ error: ProviderErrorDTO) -> AIError {
        guard let code = error.code, (400...599).contains(code) else {
            return AIError(message: "모델 제공자가 답변을 완료하지 못했어요. 잠시 후 다시 생성해 주세요.")
        }
        return statusError(code)
    }
}

nonisolated private final class OpenRouterNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated private struct ModelsResponse: Decodable {
    let data: [LossyModelDTO]
    var models: [OpenRouterModel] { data.compactMap(\.model) }
}

nonisolated private struct LossyModelDTO: Decodable {
    let model: OpenRouterModel?

    init(from decoder: Decoder) throws {
        model = try? ModelDTO(from: decoder).model
    }
}

nonisolated private struct ModelDTO: Decodable {
    let id: String
    let name: String
    let contextLength: Int?
    let architecture: ArchitectureDTO
    let pricing: PricingDTO?
    let topProvider: TopProviderDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contextLength = "context_length"
        case architecture
        case pricing
        case topProvider = "top_provider"
    }

    var model: OpenRouterModel {
        OpenRouterModel(
            id: id,
            name: name,
            contextLength: contextLength ?? 0,
            inputModalities: architecture.inputModalities,
            outputModalities: architecture.outputModalities,
            promptPrice: pricing?.prompt?.value,
            completionPrice: pricing?.completion?.value,
            maxCompletionTokens: topProvider?.maxCompletionTokens
        )
    }
}

nonisolated private struct TopProviderDTO: Decodable {
    let maxCompletionTokens: Int?
    enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
}

nonisolated private struct ArchitectureDTO: Decodable {
    let inputModalities: [String]
    let outputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }
}

nonisolated private struct PricingDTO: Decodable {
    let prompt: PriceValue?
    let completion: PriceValue?
}

nonisolated private struct PriceValue: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported price value")
            )
        }
    }
}

nonisolated private struct UsageDTO: Decodable {
    let cost: Double?

    enum CodingKeys: String, CodingKey { case cost }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Billing metadata is optional and must not discard a usable answer.
        let value = try? container.decode(PriceValue.self, forKey: .cost)
        if let value, let number = Double(value.value), number.isFinite, number >= 0 {
            cost = number
        } else {
            cost = nil
        }
    }
}

nonisolated private struct ErrorEnvelope: Decodable {
    let error: ProviderErrorDTO?
}

nonisolated private struct ProviderErrorDTO: Decodable {
    let code: Int?
    enum CodingKeys: String, CodingKey { case code }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int.self, forKey: .code) {
            code = number
        } else if let string = try? container.decode(String.self, forKey: .code) {
            code = Int(string)
        } else {
            code = nil
        }
    }
}

nonisolated private struct InputAudio: Encodable {
    let data: String
    let format: String
}

nonisolated private struct TranscriptionRequest: Encodable {
    let model: String
    let inputAudio: InputAudio
    let language: String?

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
    }
}

nonisolated private struct DetailedTranscriptionRequest: Encodable {
    let model: String
    let inputAudio: InputAudio
    let language: String?
    let responseFormat: String
    let timestampGranularities: [String]
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
        case responseFormat = "response_format"
        case timestampGranularities = "timestamp_granularities"
        case prompt
    }
}

nonisolated private struct TranscriptionResponse: Decodable {
    let text: String
    let usage: UsageDTO?

    enum CodingKeys: String, CodingKey { case text, usage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        usage = try? container.decode(UsageDTO.self, forKey: .usage)
    }
}

nonisolated private struct DetailedTranscriptionResponse: Decodable {
    private static let maxTextLength = 2_000_000
    private static let maxWordCount = 200_000
    private static let maxSegmentCount = 20_000

    let text: String
    let words: [TimedTranscriptionWordDTO]
    let segments: [TimedTranscriptionSegmentDTO]
    let usage: UsageDTO?

    enum CodingKeys: String, CodingKey { case text, words, segments, usage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        words = (try? container.decode([TimedTranscriptionWordDTO].self, forKey: .words)) ?? []
        segments = (try? container.decode([TimedTranscriptionSegmentDTO].self, forKey: .segments)) ?? []
        usage = try? container.decode(UsageDTO.self, forKey: .usage)
    }

    func result() throws -> DetailedTranscriptionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count <= Self.maxTextLength,
              words.count <= Self.maxWordCount,
              segments.count <= Self.maxSegmentCount else {
            throw AIError(message: "OpenRouter 상세 전사 응답이 너무 커서 처리할 수 없어요.")
        }
        guard !words.isEmpty || !segments.isEmpty else {
            throw AIError(message: "선택한 전사 모델이 타임스탬프를 반환하지 않았어요. 타임스탬프를 지원하는 모델을 선택해 주세요.")
        }

        let mappedWords = try validate(
            words.map {
                TimedTranscriptionWord(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: $0.start,
                    end: $0.end,
                    speakerID: $0.speakerID
                )
            },
            start: \.start,
            end: \.end
        )
        let mappedSegments = try validate(
            segments.map {
                TimedTranscriptionSegment(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: $0.start,
                    end: $0.end,
                    speakerID: $0.speakerID
                )
            },
            start: \.start,
            end: \.end
        )
        return DetailedTranscriptionResult(
            text: trimmedText,
            words: mappedWords,
            segments: mappedSegments,
            costUSD: usage?.cost
        )
    }

    private func validate<T>(
        _ items: [T],
        start: KeyPath<T, Double>,
        end: KeyPath<T, Double>
    ) throws -> [T] {
        var previousStart = 0.0
        for item in items {
            let itemStart = item[keyPath: start]
            let itemEnd = item[keyPath: end]
            guard itemStart.isFinite,
                  itemEnd.isFinite,
                  itemStart >= 0,
                  itemEnd >= itemStart,
                  itemStart >= previousStart else {
                throw AIError(message: "OpenRouter 상세 전사 응답의 타임스탬프가 올바르지 않아요.")
            }
            previousStart = itemStart
        }
        return items
    }
}

nonisolated private struct TimedTranscriptionWordDTO: Decodable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case text
        case word
        case start
        case end
        case speaker
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try (container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decode(String.self, forKey: .word))
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        speakerID = container.decodeFlexibleSpeakerID()
    }
}

nonisolated private struct TimedTranscriptionSegmentDTO: Decodable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case speaker
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        speakerID = container.decodeFlexibleSpeakerID()
    }
}

nonisolated private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int
    let stream: Bool
    let reasoning: ReasoningOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
        case reasoning
    }
}

nonisolated private struct ReasoningOptions: Encodable {
    let effort: String
    let exclude: Bool
}

nonisolated private struct ChatMessage: Encodable, Equatable {
    let role: String
    let content: String
}

nonisolated private struct ChatResponse: Decodable {
    let choices: [ChatChoice]
    let usage: UsageDTO?

    enum CodingKeys: String, CodingKey { case choices, usage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decode([ChatChoice].self, forKey: .choices)
        usage = try? container.decode(UsageDTO.self, forKey: .usage)
    }
}

nonisolated private struct ChatChoice: Decodable {
    let message: ChatResponseMessage?
    let finishReason: String?
    let error: ProviderErrorDTO?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
        case error
    }
}

nonisolated private struct ChatResponseMessage: Decodable {
    let content: String?
    let refusal: String?
}

nonisolated private extension KeyedDecodingContainer where Key == TimedTranscriptionWordDTO.CodingKeys {
    func decodeFlexibleSpeakerID() -> String? {
        if let value = (try? decodeIfPresent(String.self, forKey: .speakerID)) ?? (try? decodeIfPresent(String.self, forKey: .speaker)) {
            return value
        }
        if let value = (try? decodeIfPresent(Int.self, forKey: .speakerID)) ?? (try? decodeIfPresent(Int.self, forKey: .speaker)) {
            return String(value)
        }
        if let value = (try? decodeIfPresent(Double.self, forKey: .speakerID)) ?? (try? decodeIfPresent(Double.self, forKey: .speaker)),
           value.isFinite {
            return value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
        }
        return nil
    }
}

nonisolated private extension KeyedDecodingContainer where Key == TimedTranscriptionSegmentDTO.CodingKeys {
    func decodeFlexibleSpeakerID() -> String? {
        if let value = (try? decodeIfPresent(String.self, forKey: .speakerID)) ?? (try? decodeIfPresent(String.self, forKey: .speaker)) {
            return value
        }
        if let value = (try? decodeIfPresent(Int.self, forKey: .speakerID)) ?? (try? decodeIfPresent(Int.self, forKey: .speaker)) {
            return String(value)
        }
        if let value = (try? decodeIfPresent(Double.self, forKey: .speakerID)) ?? (try? decodeIfPresent(Double.self, forKey: .speaker)),
           value.isFinite {
            return value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
        }
        return nil
    }
}
