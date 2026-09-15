import Foundation
import Testing
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
@testable import NoteTakerIOS
#else
import AppKit
@testable import NoteTaker
#endif

@MainActor
final class WebShareSheetPresentationTests: XCTestCase {
    func testCopyCanRestoreTheLinkAfterOtherClipboardContent() throws {
        let url = try XCTUnwrap(URL(string: "https://notes.example/s/synthetic-share-address"))
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        XCTAssertTrue(WebShareClipboard.copy(url))
        XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
        pasteboard.clearContents()
        pasteboard.setString("Other clipboard content", forType: .string)
        XCTAssertTrue(WebShareClipboard.copy(url))
        XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
        #else
        let pasteboard = UIPasteboard.general
        let saved = pasteboard.items
        defer { pasteboard.items = saved }
        XCTAssertTrue(WebShareClipboard.copy(url))
        XCTAssertEqual(pasteboard.string, url.absoluteString)
        pasteboard.string = "Other clipboard content"
        XCTAssertTrue(WebShareClipboard.copy(url))
        XCTAssertEqual(pasteboard.string, url.absoluteString)
        #endif
    }

    func testActiveSharingLayoutsRenderWithoutPublishing() async throws {
        let address = try XCTUnwrap(URL(string: "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"))
        let states: [(String, URL?, ColorScheme)] = [
            ("active", address, .light),
            ("active-no-address", nil, .light),
            ("active-dark", address, .dark)
        ]
        for (name, url, colorScheme) in states {
            let view = NavigationStack {
                WebShareSheetContent(isLoading: false, progressTitle: "", shareURL: url,
                    expiresAt: Date(timeIntervalSince1970: 1_790_000_000), isActive: true, statusIsKnown: true,
                    copied: false, message: nil, errorMessage: nil,
                    publish: { XCTFail("Rendering an active link must not publish another link.") },
                    revoke: { XCTFail("Rendering must not cancel sharing.") },
                    copy: { _ in XCTFail("Rendering must not replace the clipboard.") }, openSyncSettings: {})
                    .navigationTitle(String(localized: "Share to Web"))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) {}
                        }
                    }
            }
            .environment(\.locale, Locale(identifier: "ko"))
            .preferredColorScheme(colorScheme)
            #if os(macOS)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = window.contentView!.bounds
            defer { window.close() }
            let platform = "mac"
            #else
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            host.loadViewIfNeeded()
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let platform = "iphone"
            #endif
            try await Task.sleep(for: .milliseconds(200))
            #if os(macOS)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            #else
            host.view.layoutIfNeeded()
            let png = UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            #endif
            XCTAssertGreaterThan(png.count, 10_000, "The sharing form must contain rendered content.")
            let filename = "web-share-\(name)-\(platform).png"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = filename
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appending(path: filename)
            try png.write(to: output)
            print("WEB_SHARE_RENDER: \(output.path)")
        }
    }
}

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
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json(#"{"active":true,"url":"https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ","expiresAt":1790000000000}"#),
            "DELETE /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .response(status: 204, body: "")
        ])
        let client = WebShareClient(
            configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session
        )

        let status = try await client.status(sourceID: sourceID)
        try await client.revoke(sourceID: sourceID)

        #expect(status == WebShareStatus(active: true,
            url: URL(string: "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"),
            expiresAt: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(recorder.requests.map { "\($0.value.httpMethod ?? "") \($0.value.url?.path ?? "")" } == [
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "DELETE /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        #expect(recorder.requests.allSatisfy { $0.value.value(forHTTPHeaderField: "Authorization") == "Bearer sync-secret" })
        #expect(recorder.requests.allSatisfy { !($0.value.url?.absoluteString.contains("/s/") ?? false) })
    }

    @Test("a fresh client restores the same active URL without creating another share")
    func freshClientRestoresPublishedAddress() async throws {
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let address = "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        let recorder = WebShareHTTPRecorder(routes: [
            "PUT /v1/shares/\(sourceID.uuidString)": .json("{\"url\":\"\(address)\",\"expiresAt\":1790000000000}"),
            "GET /v1/shares/\(sourceID.uuidString)": .json("{\"active\":true,\"url\":\"\(address)\",\"expiresAt\":1790000000000}")
        ])
        let configuration = try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret")
        let publication = try await WebShareClient(configuration: configuration, session: recorder.session)
            .publish(sourceID: sourceID, title: "Meeting", markdown: "Minutes")
        let restored = try await WebShareClient(configuration: configuration, session: recorder.session).status(sourceID: sourceID)
        #expect(restored.url == publication.url)
        #expect(recorder.requests.map { $0.value.httpMethod } == ["PUT", "GET"])
        #expect(recorder.requests.last?.value.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("status rejects unsafe active URLs using the publication URL rules")
    func statusValidatesReturnedPublicURL() async throws {
        for address in [
            "https://evil.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
            "http://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
            "https://notes.example:444/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
            "https://notes.example/s/short",
            "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ?token=leak",
            "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ#fragment",
            "https://user:pass@notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
        ] {
            let recorder = WebShareHTTPRecorder(routes: [
                "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json("{\"active\":true,\"url\":\"\(address)\",\"expiresAt\":1790000000000}")
            ])
            let client = WebShareClient(configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
                session: recorder.session)
            await #expect(throws: WebShareError.invalidResponse) {
                _ = try await client.status(sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
            }
        }
    }

    @Test("legacy active status without an address requires a server update")
    func missingActiveAddressIsActionable() async throws {
        let recorder = WebShareHTTPRecorder(routes: [
            "GET /v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": .json(#"{"active":true,"expiresAt":1790000000000}"#)
        ])
        let client = WebShareClient(configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session)
        await #expect(throws: WebShareError.activeLinkURLUnavailable) {
            _ = try await client.status(sourceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        }
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

@Suite("Web share sheet state")
@MainActor
struct WebShareSheetStateTests {
    private let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let address = "https://notes.example/s/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"

    @Test("new sheet state instances restore the existing URL and never publish a replacement")
    func reopeningRestoresURL() async throws {
        let recorder = fixture(active(address))
        let client = try client(recorder)
        for _ in 0..<2 {
            let state = WebShareSheetState()
            await state.refresh(sourceID: sourceID, client: { client })
            #expect(state.shareURL?.absoluteString == address)
            #expect(state.isActive && state.statusIsKnown)
            await state.publish(sourceID: sourceID, title: "Meeting", markdown: "Minutes", client: { client })
        }
        #expect(recorder.requests.map { $0.value.httpMethod } == ["GET", "GET"])
    }

    @Test("server URL changes replace local state and inactive status clears it")
    func statusIsAuthoritative() async throws {
        let state = WebShareSheetState()
        let first = try client(fixture(active(address)))
        await state.refresh(sourceID: sourceID, client: { first })
        let replacement = "https://notes.example/s/" + String(repeating: "B", count: 43)
        let changed = try client(fixture(active(replacement)))
        await state.refresh(sourceID: sourceID, client: { changed })
        #expect(state.shareURL?.absoluteString == replacement)
        let inactive = try client(fixture("{\"active\":false,\"url\":\"\(address)\",\"expiresAt\":1790000000000}"))
        await state.refresh(sourceID: sourceID, client: { inactive })
        #expect(state.shareURL == nil && state.expiresAt == nil)
        #expect(!state.isActive && state.statusIsKnown)
    }

    @Test("failed status drops the stale URL and cannot enable creation")
    func failedRefreshDoesNotKeepStaleAddress() async throws {
        let state = WebShareSheetState()
        let first = try client(fixture(active(address)))
        await state.refresh(sourceID: sourceID, client: { first })
        let invalid = fixture(active(address.replacingOccurrences(of: "notes.example", with: "evil.example")))
        let changed = try client(invalid)
        await state.refresh(sourceID: sourceID, client: { changed })
        #expect(state.shareURL == nil && state.expiresAt == nil)
        #expect(!state.statusIsKnown && state.errorMessage != nil)
        await state.publish(sourceID: sourceID, title: "Meeting", markdown: "Minutes", client: { changed })
        #expect(invalid.requests.map { $0.value.httpMethod } == ["GET"])
    }

    @Test("legacy missing URL remains cancellable without enabling replacement")
    func legacyActiveURLCanStillBeRevoked() async throws {
        let recorder = fixture(#"{"active":true,"expiresAt":1790000000000}"#)
        let client = try client(recorder)
        let state = WebShareSheetState()
        await state.refresh(sourceID: sourceID, client: { client })
        #expect(state.isActive && state.statusIsKnown)
        #expect(state.shareURL == nil && state.errorMessage != nil)
        await state.publish(sourceID: sourceID, title: "Meeting", markdown: "Minutes", client: { client })
        await state.revoke(sourceID: sourceID, client: { client })
        #expect(!state.isActive && state.shareURL == nil && state.expiresAt == nil)
        #expect(recorder.requests.map { $0.value.httpMethod } == ["GET", "DELETE"])
    }

    @Test("a late response cannot restore an old server context URL")
    func newerRefreshWins() async throws {
        let state = WebShareSheetState()
        let delayed = fixture(active(address), delay: 0.1)
        let first = try client(delayed)
        let pending = Task { await state.refresh(sourceID: sourceID, client: { first }) }
        for _ in 0..<100 where delayed.requests.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!delayed.requests.isEmpty)
        let newerAddress = "https://notes.example/s/" + String(repeating: "B", count: 43)
        let newer = try client(fixture(active(newerAddress)))
        await state.refresh(sourceID: sourceID, client: { newer })
        await pending.value
        #expect(state.shareURL?.absoluteString == newerAddress)
        #expect(state.isActive && state.statusIsKnown && !state.isLoading)
    }

    private func active(_ url: String) -> String {
        "{\"active\":true,\"url\":\"\(url)\",\"expiresAt\":1790000000000}"
    }

    private func fixture(_ body: String, delay: TimeInterval = 0) -> WebShareHTTPRecorder {
        WebShareHTTPRecorder(routes: [
            "GET /v1/shares/\(sourceID.uuidString)": .json(body, delay: delay),
            "DELETE /v1/shares/\(sourceID.uuidString)": .response(status: 204, body: "")
        ])
    }

    private func client(_ recorder: WebShareHTTPRecorder) throws -> WebShareClient {
        WebShareClient(configuration: try SyncConfiguration(endpoint: "https://notes.example", token: "sync-secret"),
            session: recorder.session)
    }
}

private final class WebShareHTTPRecorder: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]
        let delay: TimeInterval

        static func json(_ string: String, delay: TimeInterval = 0) -> Response {
            response(status: 200, body: string, headers: ["Content-Type": "application/json"], delay: delay)
        }

        static func response(status: Int, body: String, headers: [String: String] = [:], delay: TimeInterval = 0) -> Response {
            Response(status: status, body: Data(body.utf8), headers: headers, delay: delay)
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

        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
                finish(response, httpResponse: httpResponse)
            }
        } else {
            finish(response, httpResponse: httpResponse)
        }
    }

    override func stopLoading() {}

    private func finish(_ response: WebShareHTTPRecorder.Response, httpResponse: HTTPURLResponse) {
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

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
