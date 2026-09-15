import AppKit
import SwiftUI
import Vision
import XCTest
@testable import NoteTaker

@MainActor
final class WaveformFocusRenderTests: XCTestCase {
    func testLongRecordingEndShowsAbsoluteFocusedRange() async throws {
        try await renderPlayback(at: 3_122, name: "waveform-focus-end-dark",
            expectedLabels: ["49:19", "52:02", "54:19"])
    }

    func testMiddleOfRecordingShowsFiveMinuteNeighborhood() async throws {
        try await renderPlayback(at: 1_650, name: "waveform-focus-middle-dark",
            expectedLabels: ["25:00", "27:30", "30:00"])
    }

    private func renderPlayback(at currentTime: TimeInterval, name: String, expectedLabels: [String]) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WaveformFocusRender-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let recording = Recording(title: "긴 회의 · 합성 파형 검증", createdAt: Date(timeIntervalSince1970: 1_788_508_800),
            duration: 3_259, mode: .micAndSystem)
        try library.add(recording)
        let player = FocusRenderPlayer()
        let peaks = Self.syntheticPeaks
        let playback = PlaybackController(player: player, library: library, waveformSampler: { _ in peaks })
        let model = AppModel()
        model.selectedRecordingID = recording.id
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WaveformFocusRender.\(UUID())"))
        let settings = AppSettings(defaults: defaults,
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil))
        let session = RecordingSession(recorder: FakeRecorderEngine(), player: player, library: library,
            appModel: model, settings: settings)
        let controller = LibraryController(library: library, model: model, session: session, playback: playback)
        try await playback.load(recording: recording)
        for _ in 0..<100 where playback.waveformPeaks.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(playback.waveformPeaks.isEmpty)
        await playback.seek(to: currentTime)
        let view = PlaybackDetailView(recording: recording, controller: playback, libraryController: controller)
            .environment(\.locale, Locale(identifier: "ko"))
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 760, height: 460)
        let host = NSHostingView(rootView: view)
        let window = makeWindow(host: host, width: 760, height: 460)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        for label in expectedLabels {
            XCTAssertTrue(text.contains(label), "The rendered playback view must include \(label). Recognized labels: \(text)")
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/visual-qa", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appending(path: "\(name).png"))
        await playback.stop()
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        return window
    }

    private static var syntheticPeaks: [Double] {
        (0..<6_518).map { index in
            let time = Double(index) / 2
            let quiet = index % 113 < 15
            let envelope = 0.2 + 0.7 * abs(sin(time * 0.006))
            return quiet ? 0.025 : envelope * (0.15 + abs(sin(time * 0.13)) * 0.48 + abs(sin(time * 1.1)) * 0.25)
        }
    }
}

@MainActor
private final class FocusRenderPlayer: PlayerEngine {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    let duration: TimeInterval = 3_259
    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {}
    func load(url: URL) async throws { currentTime = 0 }
    func play() async throws { isPlaying = true }
    func pause() async { isPlaying = false }
    func seek(to time: TimeInterval) async { currentTime = time }
    func stop() async { isPlaying = false; currentTime = 0 }
}
