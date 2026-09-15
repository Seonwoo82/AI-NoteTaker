import Foundation
import AVFAudio

#if canImport(FoundationModels)
@preconcurrency import FoundationModels
#endif

#if canImport(Speech)
@preconcurrency import Speech
#endif

nonisolated struct AppleOnDeviceAIClient: OpenRouterServing {
    private static let completionMarker = "[[NOTE_TAKER_LOCAL_AI_COMPLETE]]"

    private let speechTimeout: Duration
    private let summaryTimeout: Duration

    init(speechTimeout: Duration = .seconds(90), summaryTimeout: Duration = .seconds(120)) {
        self.speechTimeout = speechTimeout
        self.summaryTimeout = summaryTimeout
    }

    func models() async throws -> [OpenRouterModel] {
        [LocalAIModel.summaryDescriptor] + LocalAIModel.speechDescriptors
    }

    func validateKey(_ apiKey: String) async throws {}

    func transcribe(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?
    ) async throws -> AITextResponse {
        guard let localeIdentifier = LocalAIModel.speechLocale(modelID: model) else {
            throw AIError(message: "온디바이스 전사 모델 ID가 올바르지 않습니다.")
        }
        try Task.checkCancellation()
        let chunks = try await speechChunks(audio: audio, format: format)
        var transcriptParts: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let text = try await withTimeout(speechTimeout) {
                try await transcribeSingleClip(audio: chunk.data, format: chunk.format, localeIdentifier: localeIdentifier)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                transcriptParts.append(trimmed)
            }
        }
        return AITextResponse(text: transcriptParts.joined(separator: "\n"), costUSD: 0)
    }

    func complete(
        system: String,
        user: String,
        model: String,
        apiKey: String,
        maxTokens: Int
    ) async throws -> AITextResponse {
        guard model == LocalAIModel.summaryID else {
            throw AIError(message: "온디바이스 요약 모델 ID가 올바르지 않습니다.")
        }
        guard maxTokens > 0 else {
            throw AIError(message: "온디바이스 요약 출력 토큰 예산이 올바르지 않습니다.")
        }
        try Task.checkCancellation()
        let text = try await withTimeout(summaryTimeout) {
            try await completeWithFoundationModels(system: system, user: user, maxTokens: maxTokens)
        }
        return AITextResponse(text: text, costUSD: 0)
    }

    private func speechChunks(audio: Data, format: String) async throws -> [AudioChunk] {
        guard format.lowercased() == "wav" else {
            throw AIError(message: "온디바이스 전사는 WAV 오디오만 처리할 수 있습니다.")
        }

        let sourceURL = temporaryAudioURL(format: "wav")
        try audio.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            let chunker = MeetingAudioChunker(chunkDuration: 50)
            let count = try await chunker.chunkCount(for: sourceURL)
            guard count > 1 else {
                return [AudioChunk(data: audio, format: format, startTime: 0, duration: 0)]
            }
            var chunks: [AudioChunk] = []
            chunks.reserveCapacity(count)
            for index in 0..<count {
                chunks.append(try await chunker.chunk(for: sourceURL, index: index))
            }
            return chunks
        } catch let error as CancellationError {
            throw error
        } catch {
            throw AIError(message: "온디바이스 전사용 WAV 오디오를 50초 단위로 나누지 못했습니다. 오디오 파일 형식을 확인해 주세요.")
        }
    }

    private func transcribeSingleClip(audio: Data, format: String, localeIdentifier: String) async throws -> String {
        #if canImport(Speech)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AIError(message: "온디바이스 전사를 사용하려면 음성 인식 권한이 필요합니다.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw AIError(message: "이 언어의 온디바이스 음성 인식기를 만들 수 없습니다.")
        }
        guard recognizer.isAvailable && recognizer.supportsOnDeviceRecognition else {
            throw AIError(message: "이 기기에서 \(localeIdentifier) 온디바이스 음성 인식을 사용할 수 없습니다.")
        }

        let url = temporaryAudioURL(format: format)
        try audio.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let owner = LocalAIContinuationOwner<String>()
        return try await withTaskCancellationHandler {
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            return try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation: continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        owner.resume(throwing: AIError(message: "온디바이스 전사에 실패했습니다: \(error.localizedDescription)"))
                    } else if let result, result.isFinal {
                        owner.resume(returning: result.bestTranscription.formattedString)
                    }
                }
                owner.installTask {
                    task.cancel()
                }
            }
        } onCancel: {
            owner.cancel()
        }
        #else
        throw AIError(message: "이 빌드에서 Apple 음성 인식 프레임워크를 사용할 수 없습니다.")
        #endif
    }

    private func completeWithFoundationModels(system: String, user: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AIError(message: "온디바이스 요약은 macOS 26 또는 iOS 26 이상에서 사용할 수 있습니다.")
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw AIError(message: "이 기기는 Apple Intelligence 온디바이스 모델을 지원하지 않습니다.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw AIError(message: "Apple Intelligence가 꺼져 있습니다. 시스템 설정에서 켜 주세요.")
        case .unavailable(.modelNotReady):
            throw AIError(message: "Apple Intelligence 모델이 아직 준비되지 않았습니다. 시스템 설정에서 모델 준비 상태를 확인해 주세요.")
        @unknown default:
            throw AIError(message: "온디바이스 AI 상태를 확인할 수 없습니다.")
        }

        let supportedSummaryLocale = LocalAIModel.supportedSpeechLocales
            .map { Locale(identifier: $0) }
            .contains { model.supportsLocale($0) }
        guard supportedSummaryLocale else {
            throw AIError(message: "Apple Intelligence 모델이 한국어 또는 영어 요약을 지원하지 않습니다.")
        }

        let responseLimit = min(max(maxTokens, 1), LocalAIModel.summaryDescriptor.maxCompletionTokens ?? 1_024)
        let instructions = """
        \(system)

        답변이 완전히 끝나면 마지막 줄에 \(Self.completionMarker)를 정확히 한 번 붙이세요.
        """
        let prompt = Prompt(user)
        if #available(macOS 26.4, iOS 26.4, *) {
            let tokens = try await model.tokenCount(for: Prompt("\(instructions)\n\n\(user)"))
            guard tokens + responseLimit + 64 < model.contextSize else {
                throw AIError(message: "온디바이스 모델의 컨텍스트 한도를 초과했습니다. 전사문을 줄인 뒤 다시 시도해 주세요.")
            }
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: responseLimit)
            )
            try Task.checkCancellation()
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AIError(message: "온디바이스 모델이 최종 답변을 반환하지 않았습니다.")
            }
            guard text.hasSuffix(Self.completionMarker) else {
                throw AIError(message: "온디바이스 모델 응답이 출력 길이 제한에 도달했을 수 있어 회의록을 저장하지 않았습니다. 더 짧은 녹음으로 다시 시도해 주세요.")
            }
            let strippedText = String(text.dropLast(Self.completionMarker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !strippedText.isEmpty else {
                throw AIError(message: "온디바이스 모델이 최종 답변을 반환하지 않았습니다.")
            }
            return strippedText
        } catch let error as LanguageModelSession.GenerationError {
            throw foundationModelError(error)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError(message: "온디바이스 요약에 실패했습니다: \(error.localizedDescription)")
        }
        #else
        throw AIError(message: "이 빌드에서 Apple 온디바이스 요약 프레임워크를 사용할 수 없습니다.")
        #endif
    }

    private func temporaryAudioURL(format: String) -> URL {
        let ext = format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "audio" : format.lowercased()
        return FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerLocalAI-\(UUID().uuidString).\(ext)")
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AIError(message: "온디바이스 AI 작업 시간이 초과되었습니다. 저장된 전사문은 유지됩니다.")
            }
            let result = try await group.next()!
            return result
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private func foundationModelError(_ error: LanguageModelSession.GenerationError) -> AIError {
        switch error {
        case .exceededContextWindowSize:
            AIError(message: "온디바이스 모델의 컨텍스트 한도를 초과했습니다. 전사문을 줄인 뒤 다시 시도해 주세요.")
        case .assetsUnavailable:
            AIError(message: "Apple Intelligence 모델 자산을 사용할 수 없습니다. 시스템 설정에서 모델 준비 상태를 확인해 주세요.")
        case .unsupportedLanguageOrLocale:
            AIError(message: "Apple Intelligence 모델이 이 언어를 지원하지 않습니다.")
        case .guardrailViolation, .refusal:
            AIError(message: "온디바이스 모델이 이 내용에 대한 회의록 생성을 거부했습니다.")
        case .rateLimited, .concurrentRequests:
            AIError(message: "온디바이스 모델이 바쁩니다. 잠시 후 다시 시도해 주세요.")
        default:
            AIError(message: "온디바이스 요약에 실패했습니다: \(error.localizedDescription)")
        }
    }
    #endif
}

nonisolated final class LocalAIContinuationOwner<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelTask: (@Sendable () -> Void)?
    private var terminalResult: Result<Value, Error>?

    func install(continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            resumeContinuation(continuation, with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func installTask(_ cancelTask: @escaping @Sendable () -> Void) {
        lock.lock()
        if terminalResult != nil {
            lock.unlock()
            cancelTask()
            return
        }
        self.cancelTask = cancelTask
        lock.unlock()
    }

    func resume(returning value: Value) {
        resume(.success(value))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    func cancel() {
        resume(.failure(CancellationError()))
    }

    private func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = continuation
        self.continuation = nil
        let cancelTask = cancelTask
        self.cancelTask = nil
        lock.unlock()

        cancelTask?()
        if let continuation {
            resumeContinuation(continuation, with: result)
        }
    }

    private func resumeContinuation(_ continuation: CheckedContinuation<Value, Error>, with result: Result<Value, Error>) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
