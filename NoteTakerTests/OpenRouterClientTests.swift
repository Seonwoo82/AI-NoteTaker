import Foundation
import Testing
@testable import NoteTaker

@Suite
struct OpenRouterClientTests {
    @Test("models fetches public text and transcription catalogs and skips bad DTOs")
    func modelsFetchesCatalogs() async throws {
        let recorder = HTTPRecorder(routes: [
            "GET /api/v1/models?output_modalities=text": .json("""
            {"data":[
              {"id":"google/gemini-2.5-flash","name":"Gemini","context_length":1048576,"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0.30","completion":"2.50"}},
              {"id":3,"name":"Bad"}
            ]}
            """),
            "GET /api/v1/models?output_modalities=transcription": .json("""
            {"data":[
              {"id":"openai/whisper-large-v3","name":"Whisper","context_length":0,"architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]},"pricing":{"prompt":"0.004","completion":null}}
            ]}
            """)
        ])
        let client = OpenRouterClient(session: recorder.session)

        let models = try await client.models()

        #expect(models.map(\.id) == ["google/gemini-2.5-flash", "openai/whisper-large-v3"])
        #expect(models[0].promptPrice == "0.30")
        #expect(models[1].supportsTranscription)
        #expect(recorder.requests.allSatisfy { $0.value.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test("validateKey authenticates only the key endpoint")
    func validateKeyAuthenticatesKeyEndpoint() async throws {
        let recorder = HTTPRecorder(routes: ["GET /api/v1/key": .json(#"{"data":{"label":"test"}}"#)])
        let client = OpenRouterClient(session: recorder.session)

        try await client.validateKey("sk-or-test")

        let request = try #require(recorder.requests.first?.value)
        #expect(request.url?.path == "/api/v1/key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
    }

    @Test("transcribe sends base64 JSON and permits silent chunk text")
    func transcribeSendsJSONAndAllowsEmptyText() async throws {
        let recorder = HTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json(#"{"text":"","usage":{"cost":0}}"#)
        ])
        let client = OpenRouterClient(session: recorder.session)

        let response = try await client.transcribe(
            audio: Data([0, 1, 2]),
            format: "m4a",
            model: "openai/whisper-large-v3",
            apiKey: "sk-or-secret",
            language: nil
        )

        #expect(response.text == "")
        #expect(response.costUSD == 0)
        let body = try recorder.jsonBody(at: 0)
        #expect(body["model"] as? String == "openai/whisper-large-v3")
        let inputAudio = try #require(body["input_audio"] as? [String: Any])
        #expect(inputAudio["data"] as? String == "AAEC")
        #expect(inputAudio["format"] as? String == "m4a")
        #expect(body["language"] == nil)
    }

    @Test("complete sends nonstreaming messages and rejects empty or truncated summaries")
    func completeSendsMessagesAndRejectsBadOutput() async throws {
        let success = HTTPRecorder(routes: [
            "POST /api/v1/chat/completions": .json("""
            {"choices":[{"message":{"role":"assistant","content":"요약"},"finish_reason":"stop"}],"usage":{"cost":0.0123}}
            """)
        ])
        let client = OpenRouterClient(session: success.session)

        let response = try await client.complete(system: "system", user: "user", model: "model", apiKey: "sk", maxTokens: 700)

        #expect(response.text == "요약")
        #expect(response.costUSD == 0.0123)
        let body = try success.jsonBody(at: 0)
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 700)

        let empty = HTTPRecorder(routes: [
            "POST /api/v1/chat/completions": .json(#"{"choices":[{"message":{"role":"assistant","content":"   "},"finish_reason":"stop"}]}"#)
        ])
        await #expect(throws: AIError.self) {
            _ = try await OpenRouterClient(session: empty.session)
                .complete(system: "s", user: "u", model: "m", apiKey: "sk", maxTokens: 1)
        }

        let length = HTTPRecorder(routes: [
            "POST /api/v1/chat/completions": .json(#"{"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]}"#)
        ])
        await #expect(throws: AIError.self) {
            _ = try await OpenRouterClient(session: length.session)
                .complete(system: "s", user: "u", model: "m", apiKey: "sk", maxTokens: 1)
        }
    }

    @Test("HTTP errors are Korean actionable and never include request secrets or raw body")
    func httpErrorsAreSanitized() async throws {
        let recorder = HTTPRecorder(routes: [
            "POST /api/v1/chat/completions": .response(status: 401, body: #"{"error":{"message":"bad sk-or-secret"}}"#)
        ])
        let client = OpenRouterClient(session: recorder.session)

        do {
            _ = try await client.complete(system: "s", user: "u", model: "m", apiKey: "sk-or-secret", maxTokens: 1)
            Issue.record("Expected AIError")
        } catch let error as AIError {
            #expect(error.message.contains("API 키"))
            #expect(!error.message.contains("sk-or-secret"))
            #expect(!error.message.contains("bad sk"))
        }
    }

    @Test("redirect responses fail locally without following to another origin")
    func redirectResponsesFailLocally() async throws {
        let recorder = HTTPRecorder(routes: [
            "POST /api/v1/chat/completions": .response(
                status: 302,
                body: "",
                headers: ["Location": "https://example.com/steal"]
            )
        ])
        let client = OpenRouterClient(configuration: recorder.configuration)

        await #expect(throws: AIError.self) {
            _ = try await client.complete(system: "s", user: "u", model: "m", apiKey: "sk-or-secret", maxTokens: 1)
        }

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.value.url?.host == "openrouter.ai")
    }
}

private final class HTTPRecorder: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(_ string: String) -> Response {
            response(status: 200, body: string, headers: ["Content-Type": "application/json"])
        }

        static func response(status: Int, body: String, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    private let lock = NSLock()
    private var storage: [(URLRequest, Data)] = []
    let configuration: URLSessionConfiguration
    let session: URLSession

    var requests: [(value: URLRequest, body: Data)] {
        lock.withLock { storage.map { (value: $0.0, body: $0.1) } }
    }

    init(routes: [String: Response]) {
        let id = UUID()
        configuration = .ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Recorder-ID": id.uuidString]
        session = URLSession(configuration: configuration)
        MockURLProtocol.register(routes: routes, recorderID: id) { [weak self] request, body in
            self?.lock.withLock {
                self?.storage.append((request, body))
            }
        }
    }

    func jsonBody(at index: Int) throws -> [String: Any] {
        let body = try #require(requests[safe: index]?.body)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct RouteSet: Sendable {
        let routes: [String: HTTPRecorder.Response]
        let record: @Sendable (URLRequest, Data) -> Void
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var routeSets: [String: RouteSet] = [:]

    static func register(
        routes: [String: HTTPRecorder.Response],
        recorderID: UUID,
        record: @escaping @Sendable (URLRequest, Data) -> Void
    ) {
        lock.withLock {
            routeSets[recorderID.uuidString] = RouteSet(routes: routes, record: record)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openrouter.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorderID = request.value(forHTTPHeaderField: "X-Recorder-ID") ?? ""
        let body = request.httpBody ?? readBodyStream()
        let query = request.url?.query.map { "?\($0)" } ?? ""
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")\(query)"
        let routeSet = Self.lock.withLock { Self.routeSets[recorderID] }
        routeSet?.record(request, body)

        guard let response = routeSet?.routes[key],
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
