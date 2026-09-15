import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Web share client")
@MainActor
struct WebShareClientTests {
    @Test("publish sends only title and markdown with bearer auth and uppercase source ID")
    func publishUsesShareContract() async throws {
        let recorder = WebShareHTTPRecorder(routes: [
            "PUT /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json("""
            {"url":"https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ","expiresAt":1790000000000}
            """)
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session
        )

        let response = try await client.publish(
            sourceID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            title: " Planning ",
            markdown: "# Minutes\n- Ship"
        )

        #expect(response.url.absoluteString == "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")
        #expect(response.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
        let request = try #require(recorder.requests.first?.value)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try recorder.jsonBody(at: 0)
        #expect(body["title"] as? String == "Planning")
        #expect(body["markdown"] as? String == "# Minutes\n- Ship")
        #expect(body["transcript"] == nil)
        #expect(body["audio"] == nil)
    }

    @Test("status and revoke use authenticated management endpoints without public token leakage")
    func statusAndRevokeUseManagementEndpoints() async throws {
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recorder = WebShareHTTPRecorder(routes: [
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json(#"{"active":true,"expiresAt":1790000000000}"#),
            "DELETE /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .response(status: 204, body: "")
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session
        )

        let status = try await client.status(sourceID: sourceID)
        try await client.revoke(sourceID: sourceID)

        #expect(status == WebShareStatus(active: true, expiresAt: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(recorder.requests.map { "\($0.value.httpMethod ?? "") \($0.value.url?.path ?? "")" } == [
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "DELETE /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        #expect(recorder.requests.allSatisfy { $0.value.value(forHTTPHeaderField: "Authorization") == "Bearer sync-secret" })
        #expect(recorder.requests.allSatisfy { !($0.value.url?.absoluteString.contains("/s/") ?? false) })
    }

    @Test("inactive status and server errors produce actionable state without exposing credentials")
    func errorsAreSanitized() async throws {
        let inactive = WebShareHTTPRecorder(routes: [
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json(#"{"active":false}"#)
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: inactive.session
        )
        let status = try await client.status(sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        #expect(status == WebShareStatus(active: false, expiresAt: nil))

        let failing = WebShareHTTPRecorder(routes: [
            "PUT /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .response(
                status: 500,
                body: #"{"error":{"message":"<html>bad sync-secret with a very long body that should not fill the entire sharing panel............................................................................................................................................................................................................................................</html>"}}"#
            )
        ])
        let failingClient = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: failing.session
        )

        do {
            _ = try await failingClient.publish(
                sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                title: "Planning",
                markdown: "Minutes"
            )
            Issue.record("Expected web share error")
        } catch let error as WebShareError {
            #expect(error.errorDescription?.contains("sync-secret") == false)
            #expect(error.errorDescription?.contains("<html>") == false)
            #expect((error.errorDescription?.count ?? 0) < 320)
            #expect(error.errorDescription?.contains("500") == true)
        }
    }

    @Test("publish rejects public links outside the configured share route")
    func publishValidatesReturnedPublicURL() async throws {
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        for returnedURL in [
            "https://evil.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
            "javascript:alert(1)",
            "https://notes.example/s/short",
            "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ?token=leak"
        ] {
            let recorder = WebShareHTTPRecorder(routes: [
                "PUT /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json("""
                {"url":"\(returnedURL)","expiresAt":1790000000000}
                """)
            ])
            let client = WebShareClient(
                configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
                session: recorder.session
            )

            await #expect(throws: WebShareError.invalidResponse) {
                _ = try await client.publish(sourceID: sourceID, title: "Planning", markdown: "Minutes")
            }
        }
    }

    @Test("revoke only accepts the specified no-content response")
    func revokeRequiresNoContent() async throws {
        let recorder = WebShareHTTPRecorder(routes: [
            "DELETE /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .response(status: 200, body: "<html>ok</html>")
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session
        )

        await #expect(throws: WebShareError.invalidResponse) {
            try await client.revoke(sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        }
    }

    @Test("title limit is enforced by Unicode scalar count")
    func titleLimitUsesUnicodeScalars() async throws {
        let recorder = WebShareHTTPRecorder(routes: [
            "PUT /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json("""
            {"url":"https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ","expiresAt":1790000000000}
            """)
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session
        )

        _ = try await client.publish(
            sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: String(repeating: "é", count: 300),
            markdown: "Minutes"
        )

        await #expect(throws: WebShareError.self) {
            _ = try await client.publish(
                sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                title: String(repeating: "é", count: 301),
                markdown: "Minutes"
            )
        }
    }
}

private final class WebShareHTTPRecorder: @unchecked Sendable {
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
        configuration.protocolClasses = [WebShareMockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Web-Share-Recorder-ID": id.uuidString]
        session = URLSession(configuration: configuration)
        WebShareMockURLProtocol.register(routes: routes, recorderID: id) { [weak self] request, body in
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

private final class WebShareMockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct RouteSet: Sendable {
        let routes: [String: WebShareHTTPRecorder.Response]
        let record: @Sendable (URLRequest, Data) -> Void
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var routeSets: [String: RouteSet] = [:]

    static func register(
        routes: [String: WebShareHTTPRecorder.Response],
        recorderID: UUID,
        record: @escaping @Sendable (URLRequest, Data) -> Void
    ) {
        lock.withLock {
            routeSets[recorderID.uuidString] = RouteSet(routes: routes, record: record)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "notes.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorderID = request.value(forHTTPHeaderField: "X-Web-Share-Recorder-ID") ?? ""
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
