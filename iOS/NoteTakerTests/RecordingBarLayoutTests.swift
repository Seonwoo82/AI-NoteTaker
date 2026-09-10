import SwiftUI
import UIKit
import XCTest
@testable import NoteTakerIOS

/// Render capture controls without starting a microphone or touching the real library.
@MainActor
final class RecordingBarLayoutTests: XCTestCase {
    func testRecordingControlsAtPhoneWidthsAndDynamicType() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recording-bar-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryAppModel(services: .uiTesting(), aiEnvironment: .testing())
        await model.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        model.recorder.isRecording = true
        let cases: [(String, CGFloat, DynamicTypeSize, Bool, Bool, String)] = [
            ("recording-393", 393, .large, false, false, "ko_KR"),
            ("recording-320", 320, .large, false, false, "ko_KR"),
            ("paused-320", 320, .xxxLarge, true, false, "ko_KR"),
            ("accessibility-393", 393, .accessibility3, false, false, "ko_KR"),
            ("maximum-text-320", 320, .accessibility5, false, false, "ko_KR"),
            ("saving-393", 393, .large, false, true, "ko_KR"),
            ("english-320", 320, .xxxLarge, false, false, "en_US")
        ]
        for (name, width, typeSize, paused, busy, locale) in cases {
            model.recorder.isPaused = paused
            model.recorder.isBusy = busy
            model.recorder.isRecording = !busy
            model.recorder.elapsed = name == "recording-393" ? 2 : 3_725
            let view = RecordingBar(model: model)
                .environment(\.locale, Locale(identifier: locale))
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.colorScheme, .dark)
            try await render(view, width: width, name: name)
        }
        XCTAssertTrue(model.library?.recordings.isEmpty == true)
    }

    func testRecordingBarFitsTheFullLibrarySafeArea() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recording-library-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryAppModel(services: .uiTesting(), aiEnvironment: .testing())
        await model.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let library = try XCTUnwrap(model.library)
        _ = try library.folderStore.create(name: "프로젝트 회의")
        try library.add(Recording(title: "이번 주 일정 검토", duration: 945, mode: .micOnly))
        model.recorder.isRecording = true
        model.recorder.elapsed = 2
        try await render(RootView(model: model)
            .environment(\.locale, Locale(identifier: "ko_KR"))
            .environment(\.colorScheme, .dark)
            .frame(width: 393, height: 852), width: 393, name: "full-library-393")
    }

    func testPendingSaveLayoutKeepsRecoveryActionsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recording-bar-pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = LayoutRecordingBackend()
        let recorder = VoiceRecorder(backend: backend)
        let model = LibraryAppModel(services: AppServices(recorder: recorder, player: VoicePlayer()), aiEnvironment: .testing())
        await model.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let library = try XCTUnwrap(model.library)
        await recorder.start(library: library, mode: .micOnly)
        // Make the metadata destination unwritable while retaining the fixture audio.
        try FileManager.default.createDirectory(at: library.paths.metadataURL(for: backend.id), withIntermediateDirectories: true)
        let recording = await recorder.finish(library: library)
        XCTAssertNil(recording)
        XCTAssertTrue(recorder.hasPendingRecording)
        for (name, typeSize) in [("pending-320", DynamicTypeSize.large), ("pending-accessibility-320", .accessibility3)] {
            try await render(RecordingBar(model: model).environment(\.locale, Locale(identifier: "ko_KR"))
                .environment(\.dynamicTypeSize, typeSize).environment(\.colorScheme, .dark), width: 320, name: name)
        }
        XCTAssertTrue(recorder.hasPendingRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audioURL(for: Recording(id: backend.id, title: "fixture", duration: 10, mode: .micOnly)).path))
    }

    private func render<Content: View>(_ content: Content, width: CGFloat, name: String) async throws {
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        controller.overrideUserInterfaceStyle = .dark
        controller.loadViewIfNeeded()
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 1_200))
        XCTAssertLessThanOrEqual(size.width, width + 1, "Capture bar must stay inside the phone width")
        XCTAssertLessThan(size.height, 900, "Controls must leave usable screen space")
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
        controller.view.backgroundColor = .black
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = repo.appending(path: "build/visual-qa/recording-bar")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appending(path: "\(name).png"))
        XCTAssertGreaterThan(png.count, 1_000)
    }
}

@MainActor
private final class LayoutRecordingBackend: VoiceRecordingBackend {
    let id = UUID()
    func makeRecordingID() -> UUID { id }
    func start(outputURL: URL, mode: CaptureMode, liveAudioHandler: LiveAudioSampleHandler?,
               interruptionHandler: @escaping @MainActor @Sendable () async -> Void) async throws -> any VoiceRecordingSession {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture audio".utf8).write(to: outputURL)
        return LayoutRecordingSession()
    }
}

@MainActor
private final class LayoutRecordingSession: VoiceRecordingSession {
    let canPause = true
    func pause() throws { }
    func resume() throws { }
    func finish() async throws -> VoiceRecordingResult { VoiceRecordingResult(duration: 10, warnings: []) }
    func cancel() async { }
}
