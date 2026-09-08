import Foundation
import Testing
@testable import NoteTaker

@Suite
struct DetailedTranscriptionTests {
    @Test("detailed transcription requests verbose word and segment timestamps")
    func detailedTranscriptionRequestsVerboseTimestamps() async throws {
        let recorder = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json("""
            {
              "text":"Hello there",
              "segments":[{"text":"Hello there","start":0.0,"end":1.25,"speaker":2}],
              "words":[{"word":"Hello","start":0.0,"end":0.5,"speaker":"owner"},{"text":"there","start":0.55,"end":1.25,"speaker_id":2}],
              "usage":{"cost":"0.0012"}
            }
            """)
        ])
        let client = OpenRouterClient(session: recorder.session)

        let response = try await client.transcribeDetailed(
            audio: Data([0, 1, 2]),
            format: "m4a",
            model: "openai/whisper-large-v3",
            apiKey: "sk-or-secret",
            language: "ko",
            prompt: "회의 용어: OMX, D1"
        )

        #expect(response.text == "Hello there")
        #expect(response.costUSD == 0.0012)
        #expect(response.segments == [
            TimedTranscriptionSegment(text: "Hello there", start: 0.0, end: 1.25, speakerID: "2")
        ])
        #expect(response.words == [
            TimedTranscriptionWord(text: "Hello", start: 0.0, end: 0.5, speakerID: "owner"),
            TimedTranscriptionWord(text: "there", start: 0.55, end: 1.25, speakerID: "2")
        ])

        let request = try #require(recorder.requests.first?.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-secret")
        #expect(request.timeoutInterval == 70)

        let body = try recorder.jsonBody(at: 0)
        #expect(body["model"] as? String == "openai/whisper-large-v3")
        #expect(body["language"] as? String == "ko")
        #expect(body["response_format"] as? String == "verbose_json")
        #expect(body["timestamp_granularities"] as? [String] == ["segment", "word"])
        #expect(body["prompt"] as? String == "회의 용어: OMX, D1")
        let inputAudio = try #require(body["input_audio"] as? [String: Any])
        #expect(inputAudio["data"] as? String == "AAEC")
        #expect(inputAudio["format"] as? String == "m4a")
    }

    @Test("detailed transcription omits empty optional prompt and language")
    func detailedTranscriptionOmitsEmptyOptionalFields() async throws {
        let recorder = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json("""
            {"text":"A","segments":[{"text":"A","start":0,"end":1}],"words":[{"text":"A","start":0,"end":1}]}
            """)
        ])

        _ = try await OpenRouterClient(session: recorder.session).transcribeDetailed(
            audio: Data([65]),
            format: "wav",
            model: "openai/whisper-large-v3",
            apiKey: "sk",
            language: "",
            prompt: "   "
        )

        let body = try recorder.jsonBody(at: 0)
        #expect(body["language"] == nil)
        #expect(body["prompt"] == nil)
    }

    @Test("detailed transcription reports unsupported timing when timestamps are missing")
    func detailedTranscriptionRejectsMissingTimestamps() async throws {
        let recorder = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json(#"{"text":"No timestamps"}"#)
        ])

        do {
            _ = try await OpenRouterClient(session: recorder.session).transcribeDetailed(
                audio: Data([1]),
                format: "m4a",
                model: "openai/whisper-large-v3",
                apiKey: "sk",
                language: nil,
                prompt: nil
            )
            Issue.record("Expected unsupported timing error")
        } catch let error as AIError {
            #expect(error.message.contains("타임스탬프"))
        }
    }

    @Test("detailed transcription rejects unordered and negative timestamp ranges")
    func detailedTranscriptionRejectsInvalidTimes() async throws {
        let negative = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json("""
            {"text":"Bad","segments":[{"text":"Bad","start":0,"end":1}],"words":[{"text":"Bad","start":-0.1,"end":0.2}]}
            """)
        ])
        await #expect(throws: AIError.self) {
            _ = try await OpenRouterClient(session: negative.session).transcribeDetailed(
                audio: Data([1]),
                format: "m4a",
                model: "openai/whisper-large-v3",
                apiKey: "sk",
                language: nil,
                prompt: nil
            )
        }

        let unordered = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .json("""
            {"text":"Bad","segments":[{"text":"Bad","start":2,"end":1}],"words":[{"text":"Bad","start":0,"end":1}]}
            """)
        ])
        await #expect(throws: AIError.self) {
            _ = try await OpenRouterClient(session: unordered.session).transcribeDetailed(
                audio: Data([1]),
                format: "m4a",
                model: "openai/whisper-large-v3",
                apiKey: "sk",
                language: nil,
                prompt: nil
            )
        }
    }

    @Test("detailed transcription preserves sanitized OpenRouter HTTP errors")
    func detailedTranscriptionPreservesSanitizedHTTPErrors() async throws {
        let recorder = DetailedHTTPRecorder(routes: [
            "POST /api/v1/audio/transcriptions": .response(status: 429, body: #"{"error":{"message":"secret sk-or-secret"}}"#)
        ])

        do {
            _ = try await OpenRouterClient(session: recorder.session).transcribeDetailed(
                audio: Data([1]),
                format: "m4a",
                model: "openai/whisper-large-v3",
                apiKey: "sk-or-secret",
                language: nil,
                prompt: nil
            )
            Issue.record("Expected rate-limit error")
        } catch let error as AIError {
            #expect(error.message.contains("요청 한도"))
            #expect(!error.message.contains("secret"))
            #expect(!error.message.contains("sk-or-secret"))
        }
    }
}

private final class DetailedHTTPRecorder: @unchecked Sendable {
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
        configuration.protocolClasses = [DetailedMockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Detailed-Recorder-ID": id.uuidString]
        session = URLSession(configuration: configuration)
        DetailedMockURLProtocol.register(routes: routes, recorderID: id) { [weak self] request, body in
            self?.lock.withLock {
                self?.storage.append((request, body))
            }
        }
    }

    func jsonBody(at index: Int) throws -> [String: Any] {
        let body = try #require(requests[detailedSafe: index]?.body)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }
}

private final class DetailedMockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct RouteSet: Sendable {
        let routes: [String: DetailedHTTPRecorder.Response]
        let record: @Sendable (URLRequest, Data) -> Void
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var routeSets: [String: RouteSet] = [:]

    static func register(
        routes: [String: DetailedHTTPRecorder.Response],
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
        let recorderID = request.value(forHTTPHeaderField: "X-Detailed-Recorder-ID") ?? ""
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
    subscript(detailedSafe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
