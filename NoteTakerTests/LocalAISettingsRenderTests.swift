import SwiftUI
import XCTest
#if os(macOS)
import AppKit
@testable import NoteTaker
#else
import UIKit
@testable import NoteTakerIOS
#endif

@MainActor
final class LocalAISettingsRenderTests: XCTestCase {
    func testOpeningLocalSettingsDoesNotFetchCloudModels() async throws {
        let client = LocalSettingsCloudSpy()
        let suite = "LocalAISettingsRender.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var statusChecks = 0
        let configuration = AIConfiguration(client: client, keyStore: InMemoryAPIKeyStore(), defaults: defaults,
            localStatusProvider: { _ in
                statusChecks += 1
                return LocalAIStatus(isAvailable: true, message: "이 기기에서 무료 AI를 사용할 수 있습니다.")
            })
        configuration.processingMode = .onDevice
        let initialStatusChecks = statusChecks
        let view = AISettingsView(configuration: configuration)
            .environment(\.locale, Locale(identifier: "ko"))
            .preferredColorScheme(.light)
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #else
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        host.loadViewIfNeeded()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #endif
        try await Task.sleep(for: .milliseconds(250))
        let calls = await client.modelCalls
        XCTAssertGreaterThan(statusChecks, initialStatusChecks, "The local settings task must actually run.")
        XCTAssertEqual(calls, 0, "Opening local settings must not fetch a cloud model catalog.")
        #if os(macOS)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let name = "local-ai-settings-mac.png"
        #else
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let name = "local-ai-settings-iphone.png"
        #endif
        XCTAssertGreaterThan(png.count, 10_000, "The settings capture must contain rendered UI.")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appending(path: name)
        try png.write(to: output)
        print("LOCAL_AI_SETTINGS_RENDER: \(output.path)")
    }
}

private actor LocalSettingsCloudSpy: OpenRouterServing {
    private(set) var modelCalls = 0
    func models() async throws -> [OpenRouterModel] { modelCalls += 1; return [] }
    func validateKey(_ apiKey: String) async throws { throw AIError(message: "Unexpected cloud key validation") }
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        throw AIError(message: "Unexpected cloud transcription")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        throw AIError(message: "Unexpected cloud completion")
    }
}
