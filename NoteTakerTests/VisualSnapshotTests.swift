import AppKit
import AVFAudio
import AudioPipeline
import SwiftUI
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct VisualSnapshotTests {
    @Test("shared workspace views render nonempty visual QA snapshots")
    func sharedWorkspaceViewsRenderNonemptyVisualQASnapshots() async throws {
        let outputDirectory = visualSnapshotRepositoryRoot
            .appending(path: "build/visual-qa", directoryHint: URL.DirectoryHint.isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let cases = try await makeSnapshotCases()
        for snapshotCase in cases {
            let url = outputDirectory.appending(path: "\(snapshotCase.name).png")
            try render(snapshotCase.view, colorScheme: snapshotCase.colorScheme, to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try #require(attributes[FileAttributeKey.size] as? Int)

            #expect(size > 45_000)
        }
    }

    private func makeSnapshotCases() async throws -> [SnapshotCase] {
        let empty = await SnapshotHarness.make()

        let recording = await SnapshotHarness.make()
        await recording.container.session.start()

        let paused = await SnapshotHarness.make()
        await paused.container.session.start()
        await paused.container.session.pause()
        await waitForSnapshotWaveform(paused.container.playback)

        let playback = await SnapshotHarness.make()
        let playableRecording = try await playback.addRecording(title: "새로운 녹음", duration: 64)
        playback.container.model.selectedRecordingID = playableRecording.id
        try await playback.container.playback.load(recording: playableRecording)
        await waitForSnapshotWaveform(playback.container.playback)
        await playback.container.playback.seek(to: 5)

        let favorites = await SnapshotHarness.make()
        _ = try await favorites.addRecording(title: "즐겨찾는 회의", duration: 96, isFavorite: true)
        await favorites.container.libraryController.selectFolder(.favorites)

        let recentlyDeleted = await SnapshotHarness.make()
        let deletedRecording = try await recentlyDeleted.addRecording(title: "삭제 예정 메모", duration: 18, deletedAt: Date())
        await recentlyDeleted.container.libraryController.selectFolder(.recentlyDeleted)
        recentlyDeleted.container.model.selectedRecordingID = deletedRecording.id
        try await recentlyDeleted.container.playback.load(recording: deletedRecording)
        await waitForSnapshotWaveform(recentlyDeleted.container.playback)

        let settings = await SnapshotHarness.make()

        let error = await SnapshotHarness.make()
        let brokenRecording = try await error.addRecording(title: "복구된 녹음", duration: 24)
        error.container.model.selectedRecordingID = brokenRecording.id
        error.player.loadError = PlayerEngineError.failed("선택한 오디오를 열 수 없습니다.")
        try? await error.container.playback.load(recording: brokenRecording)

        return [
            SnapshotCase(name: "empty-light", view: AnyView(empty.workspace(.empty)), colorScheme: .light),
            SnapshotCase(name: "recording-light", view: AnyView(recording.workspace(.recording)), colorScheme: .light),
            SnapshotCase(name: "paused-light", view: AnyView(paused.workspace(.recording)), colorScheme: .light),
            SnapshotCase(name: "playback-light", view: AnyView(playback.workspace(.playback(playableRecording))), colorScheme: .light),
            SnapshotCase(name: "favorites-light", view: AnyView(favorites.workspace(.empty)), colorScheme: .light),
            SnapshotCase(name: "recently-deleted-light", view: AnyView(recentlyDeleted.workspace(.playback(deletedRecording))), colorScheme: .light),
            SnapshotCase(name: "settings-light", view: AnyView(settings.settingsView), colorScheme: .light),
            SnapshotCase(name: "error-light", view: AnyView(error.workspace(.playback(brokenRecording))), colorScheme: .light),
            SnapshotCase(name: "empty-dark", view: AnyView(empty.workspace(.empty)), colorScheme: .dark),
            SnapshotCase(name: "recording-dark", view: AnyView(recording.workspace(.recording)), colorScheme: .dark),
            SnapshotCase(name: "paused-dark", view: AnyView(paused.workspace(.recording)), colorScheme: .dark),
            SnapshotCase(name: "playback-dark", view: AnyView(playback.workspace(.playback(playableRecording))), colorScheme: .dark),
            SnapshotCase(name: "favorites-dark", view: AnyView(favorites.workspace(.empty)), colorScheme: .dark),
            SnapshotCase(name: "recently-deleted-dark", view: AnyView(recentlyDeleted.workspace(.playback(deletedRecording))), colorScheme: .dark),
            SnapshotCase(name: "error-dark", view: AnyView(error.workspace(.playback(brokenRecording))), colorScheme: .dark)
        ]
    }

    private func render(_ view: AnyView, colorScheme: ColorScheme, to url: URL) throws {
        let rootView = view
            .environment(\.colorScheme, colorScheme)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 900, height: 560)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        hostingView.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.couldNotCreateBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG
        }
        try png.write(to: url, options: .atomic)
    }
}

private enum SnapshotDetail {
    case empty
    case recording
    case playback(Recording)
}

@MainActor
private struct SnapshotHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let player: FakePlayerEngine
    let container: AppContainer

    static func make() async -> SnapshotHarness {
        let paths = LibraryPaths(libraryRoot: uniqueVisualSnapshotLibraryRoot(), arguments: [])
        let player = FakePlayerEngine()
        let container = await AppContainer.load(
            services: AppServices(
                recorder: FakeRecorderEngine(),
                player: player,
                audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
            ),
            paths: paths
        )
        let harness = SnapshotHarness(paths: paths, store: container.library, player: player, container: container)
        _ = try? await harness.addRecording(title: "아이디어 메모", duration: 42, selected: false)
        _ = try? await harness.addRecording(title: "회의 기록", duration: 186, selected: false)
        return harness
    }

    func addRecording(
        title: String,
        duration: TimeInterval,
        selected: Bool = true,
        isFavorite: Bool = false,
        deletedAt: Date? = nil
    ) async throws -> Recording {
        let recording = Recording(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_788_508_800 + duration),
            duration: duration,
            mode: .micAndSystem,
            isFavorite: isFavorite,
            deletedAt: deletedAt
        )
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try writeAudioFixture(to: paths.audioURL(for: recording.id), duration: duration)
        try store.add(recording)
        if selected {
            container.model.selectedRecordingID = recording.id
        }
        return recording
    }

    func workspace(_ detail: SnapshotDetail) -> some View {
        WorkspaceContentView(container: container)
        .onAppear {
            switch detail {
            case .empty:
                container.model.selectedRecordingID = nil
            case .recording:
                break
            case .playback(let recording):
                container.model.selectedRecordingID = recording.id
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 900, height: 560)
    }

    var settingsView: some View {
        SettingsView(settings: container.settings, session: container.session)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 900, height: 560)
    }
}

private struct SnapshotCase {
    let name: String
    let view: AnyView
    let colorScheme: ColorScheme
}

private enum SnapshotError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
}

private func uniqueVisualSnapshotLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerVisualSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private var visualSnapshotRepositoryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func writeAudioFixture(to url: URL, duration: TimeInterval) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    ) else {
        return
    }
    let frameCount = AVAudioFrameCount(max(4_800, Int(48_000 * min(duration, 2))))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channels = buffer.floatChannelData else {
        return
    }
    buffer.frameLength = frameCount
    for frame in 0..<Int(frameCount) {
        let phase = Float(frame) / 48_000
        let slow = abs(sinf(phase * 2.7))
        let medium = abs(sinf(phase * 9.1 + 0.8))
        let pulse = frame % 37_913 < 12_400 ? Float(0.18) : Float(0)
        let envelope = min(Float(0.96), Float(0.16) + slow * 0.48 + medium * 0.24 + pulse)
        channels[0][frame] = sinf(phase * 347 * 2 * Float.pi) * envelope
        channels[1][frame] = sinf((phase * 587 + sinf(phase * 3) * 0.08) * 2 * Float.pi) * envelope * 0.82
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
}

@MainActor
private func waitForSnapshotWaveform(_ playback: PlaybackController) async {
    for _ in 0..<200 {
        if !playback.waveformPeaks.isEmpty {
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
