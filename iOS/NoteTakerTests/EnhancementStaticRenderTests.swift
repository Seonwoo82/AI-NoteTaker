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
final class EnhancementStaticRenderTests: XCTestCase {
    func testParticipantTranscriptAndEnhancementSheetRender() async throws {
        let environment = AIEnvironment.testing(configured: true)
        let configuration = AIConfiguration(client: environment.client, keyStore: environment.keyStore, defaults: environment.defaults)
        await configuration.refreshModels()
        configuration.modelID = "fixture/summary"
        configuration.transcriptionModelID = "fixture/transcription"
        let root = FileManager.default.temporaryDirectory.appending(path: "enhancement-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let recording = Recording(title: "제품 출시 회의", duration: 3_600, mode: .micOnly)
        try library.add(recording)
        let transcript = MeetingTranscript(recordingID: recording.id, audioVersion: recording.audioVersion,
            transcriptionModelID: "fixture/transcription",
            speakers: [MeetingSpeaker(id: "a", name: "참여자 1", isOwner: false), MeetingSpeaker(id: "b", name: "참여자 2", isOwner: false)],
            turns: [TranscriptTurn(id: "t1", start: 0, end: 5, speakerID: "a", text: "7월 출시는 확정 일정이 아니라 목표입니다."),
                    TranscriptTurn(id: "t2", start: 6, end: 12, speakerID: "b", text: "예산 검토를 마친 뒤 출시 일정을 확정하겠습니다."),
                    TranscriptTurn(id: "t3", start: 13, end: 16, speakerID: "a", text: "변경된 일정은 회의록에도 반영해 주세요."),
                    TranscriptTurn(id: "t4", start: 18, end: 20, speakerID: nil, text: "목소리가 겹쳐 참여자를 확인하기 어려운 구간입니다.")])
        let document = MeetingNotesDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
            generatedAt: Date(timeIntervalSince1970: 1_756_800_000), modelID: "fixture/summary",
            transcriptionModelID: "fixture/transcription", markdown: "# 제품 출시 회의\n\n7월 출시가 확정 일정으로 기록되었습니다.",
            transcript: NumberedTranscript.text(transcript), speakerTranscript: transcript)
        try AIArtifactStore(paths: library.paths).saveDocument(document, recording: recording)
        let service = MeetingNotesService(configuration: configuration, client: environment.client,
            chunker: environment.chunker, library: library)
        await service.load(recording)
        let correction = "7월 출시는 확정 일정이 아니라 목표입니다. 예산 검토를 마친 뒤 최종 일정을 정하기로 했다는 맥락을 반영해 주세요."
        try render(NumberedTranscriptView(transcript: transcript).padding(24), name: "numbered-transcript")
        try render(MeetingEnhancementView(recording: recording, service: service, configuration: configuration,
            onOpenSettings: {}, onClose: {}, initialInstructions: correction), name: "enhancement-ready")
        service.enhance(recording, instructions: correction)
        for _ in 0..<400 {
            if !service.progress(for: recording.id).isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(service.enhancementPreview(for: recording.id))
        try render(MeetingEnhancementView(recording: recording, service: service, configuration: configuration,
            onOpenSettings: {}, onClose: {}, initialInstructions: correction), name: "enhancement-preview")
        try render(AISettingsView(configuration: configuration), name: "enhancement-settings")
        let cleanupSource = try TranscriptCleanupSource.make(transcript: document.transcript, speakerTranscript: transcript)
        var cleanedDocument = document
        cleanedDocument.transcriptCleanup = TranscriptCleanup(modelID: "fixture/summary", sourceKind: .speakers,
            sourceHash: cleanupSource.hash, passages: cleanupSource.passages.map {
                TranscriptCleanupPassage(id: $0.id, text: $0.id == "t4" ? "" : $0.text)
            })
        try AIArtifactStore(paths: library.paths).saveDocument(cleanedDocument, recording: recording)
        await service.reload(recording)
        try render(MeetingNotesView(recording: recording, service: service, configuration: configuration,
            initiallyShowsTranscript: true), name: "transcript-cleaned")
        try render(MeetingNotesView(recording: recording, service: service, configuration: configuration,
            initiallyShowsTranscript: true, initiallyShowsOriginalTranscript: true), name: "transcript-original")
    }

    private func render<Content: View>(_ content: Content, name: String) throws {
        #if os(macOS)
        let width: CGFloat = 760
        let height: CGFloat = 900
        let background = Color(nsColor: .windowBackgroundColor)
        #else
        let width: CGFloat = 390
        let height: CGFloat = 844
        let background = Color(uiColor: .systemBackground)
        #endif
        let view = content.environment(\.locale, Locale(identifier: "ko_KR"))
            .environment(\.colorScheme, .dark).background(background)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let png: Data
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let platform = "mac"
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #else
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = .dark
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.backgroundColor = .systemBackground
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        png = try XCTUnwrap(image.pngData())
        let platform = "ios"
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #endif
        let out = repo.appending(path: "build/visual-qa")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png.write(to: out.appending(path: "\(name)-\(platform).png"))
        XCTAssertGreaterThan(png.count, 10_000)
    }
}
