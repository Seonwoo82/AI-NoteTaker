import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct PlaybackControllerTests {
    @Test("loading a selection stops current playback and loads the recording URL")
    func loadingSelectionStopsCurrentPlaybackAndLoadsRecordingURL() async throws {
        let harness = await PlaybackControllerHarness.make()
        let first = try await harness.addRecording(duration: 40)
        let second = try await harness.addRecording(duration: 12)

        try await harness.controller.load(recording: first)
        await harness.controller.play()
        try await harness.controller.load(recording: second)

        #expect(harness.player.stopCallCount == 1)
        #expect(harness.player.loadedURLs == [
            harness.paths.audioURL(for: first.id),
            harness.paths.audioURL(for: second.id)
        ])
        #expect(harness.controller.selectedRecordingID == second.id)
        #expect(harness.controller.currentTime == 0)
        #expect(harness.controller.duration == 12)
        #expect(!harness.controller.isPlaying)
    }

    @Test("transport clamps seek and skip requests")
    func transportClampsSeekAndSkipRequests() async throws {
        let harness = await PlaybackControllerHarness.make()
        let recording = try await harness.addRecording(duration: 40)
        try await harness.controller.load(recording: recording)

        await harness.controller.seek(to: -4)
        #expect(harness.controller.currentTime == 0)
        #expect(harness.player.seekRequests == [0])

        await harness.controller.skipForward()
        #expect(harness.controller.currentTime == 15)
        await harness.controller.seek(to: 100)
        #expect(harness.controller.currentTime == 40)
        await harness.controller.skipBackward()
        #expect(harness.controller.currentTime == 25)
    }

    @Test("preview transport can play seek and skip without a selected recording")
    func previewTransportCanPlaySeekAndSkipWithoutSelectedRecording() async throws {
        let harness = await PlaybackControllerHarness.make()
        let previewURL = harness.paths.libraryRoot.appending(path: "preview.m4a")

        try await harness.controller.loadPreview(url: previewURL, duration: 40)
        await harness.controller.play()
        await harness.controller.seek(to: 100)
        await harness.controller.skipBackward()
        await harness.controller.skipForward()

        #expect(harness.controller.selectedRecordingID == nil)
        #expect(harness.player.loadedURLs == [previewURL])
        #expect(harness.player.playCallCount == 1)
        #expect(harness.player.seekRequests == [40, 25, 40])
        #expect(harness.controller.currentTime == 40)
    }

    @Test("preview play pause toggles expose observable transport state")
    func previewPlayPauseTogglesExposeObservableTransportState() async throws {
        let harness = await PlaybackControllerHarness.make()
        let previewURL = harness.paths.libraryRoot.appending(path: "preview.m4a")

        try await harness.controller.loadPreview(url: previewURL, duration: 12)
        await harness.controller.togglePlayPause()

        #expect(harness.controller.isPlaying)
        #expect(harness.player.playCallCount == 1)

        harness.player.currentTime = 4
        await harness.controller.togglePlayPause()

        #expect(!harness.controller.isPlaying)
        #expect(harness.player.pauseCallCount == 1)
        #expect(harness.controller.currentTime == 4)
    }

    @Test("loading preview exposes sampled waveform peaks")
    func loadingPreviewExposesSampledWaveformPeaks() async throws {
        let paths = LibraryPaths(libraryRoot: uniquePlaybackControllerLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let player = FakePlayerEngine()
        let previewURL = paths.libraryRoot.appending(path: "preview.m4a")
        let controller = PlaybackController(
            player: player,
            library: store,
            waveformSampler: { url in
                url == previewURL ? [0.15, 0.7, 0.35] : []
            }
        )

        try await controller.loadPreview(url: previewURL, duration: 12)
        await waitForPlaybackState { controller.waveformPeaks == [0.15, 0.7, 0.35] }

        #expect(controller.waveformPeaks == [0.15, 0.7, 0.35])
    }

    @Test("pause preserves position and play at end restarts from zero")
    func pausePreservesPositionAndPlayAtEndRestartsFromZero() async throws {
        let harness = await PlaybackControllerHarness.make()
        let recording = try await harness.addRecording(duration: 20)
        try await harness.controller.load(recording: recording)

        await harness.controller.seek(to: 6)
        await harness.controller.play()
        harness.player.currentTime = 9
        await harness.controller.pause()

        #expect(harness.controller.currentTime == 9)
        #expect(!harness.controller.isPlaying)

        await harness.controller.seek(to: 20)
        await harness.controller.play()

        #expect(harness.player.seekRequests.suffix(1) == [0])
        #expect(harness.controller.currentTime == 0)
        #expect(harness.controller.isPlaying)
    }

    @Test("playback end remains at duration")
    func playbackEndRemainsAtDuration() async throws {
        let harness = await PlaybackControllerHarness.make()
        let recording = try await harness.addRecording(duration: 20)
        try await harness.controller.load(recording: recording)

        await harness.controller.play()
        harness.player.finish()
        await Task.yield()

        #expect(harness.controller.currentTime == 20)
        #expect(!harness.controller.isPlaying)
    }

    @Test("load failure keeps the recording row selected and exposes an error")
    func loadFailureKeepsTheRecordingRowSelectedAndExposesError() async throws {
        let harness = await PlaybackControllerHarness.make()
        let recording = try await harness.addRecording(duration: 20)
        harness.player.loadError = PlayerEngineError.failed("Cannot open audio.")

        try? await harness.controller.load(recording: recording)

        #expect(harness.store.recordings.map(\.id) == [recording.id])
        #expect(harness.controller.selectedRecordingID == recording.id)
        #expect(harness.controller.errorMessage == "Cannot open audio.")
        #expect(!harness.controller.isPlaying)
    }

    @Test("play is disabled after a selected recording fails to load")
    func playIsDisabledAfterSelectedRecordingFailsToLoad() async throws {
        let harness = await PlaybackControllerHarness.make()
        let valid = try await harness.addRecording(duration: 20)
        let missing = try await harness.addRecording(duration: 12)

        try await harness.controller.load(recording: valid)
        await harness.controller.play()
        #expect(harness.player.playCallCount == 1)

        harness.player.loadError = PlayerEngineError.failed("Cannot open selected audio.")
        try? await harness.controller.load(recording: missing)
        await harness.controller.play()

        #expect(harness.controller.selectedRecordingID == missing.id)
        #expect(harness.controller.errorMessage == "Cannot open selected audio.")
        #expect(harness.player.playCallCount == 1)
        #expect(!harness.controller.isPlaying)
    }

    @Test("failed selected recording load clears preview transport so stale audio cannot replay")
    func failedSelectedRecordingLoadClearsPreviewTransportSoStaleAudioCannotReplay() async throws {
        let harness = await PlaybackControllerHarness.make()
        let missing = try await harness.addRecording(duration: 12)
        let previewURL = harness.paths.libraryRoot.appending(path: "preview.m4a")

        try await harness.controller.loadPreview(url: previewURL, duration: 30)
        await harness.controller.play()
        #expect(harness.player.playCallCount == 1)

        harness.player.loadError = PlayerEngineError.failed("Cannot open selected audio.")
        try? await harness.controller.load(recording: missing)
        await harness.controller.play()

        #expect(harness.controller.selectedRecordingID == missing.id)
        #expect(harness.controller.errorMessage == "Cannot open selected audio.")
        #expect(harness.player.playCallCount == 1)
        #expect(!harness.controller.isPlaying)
    }

    @Test("stale preview load completion after stop cannot re-enable transport")
    func stalePreviewLoadCompletionAfterStopCannotReenableTransport() async throws {
        let paths = LibraryPaths(libraryRoot: uniquePlaybackControllerLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let player = ControlledLoadPlayerEngine()
        let previewURL = paths.libraryRoot.appending(path: "preview.m4a")
        let controller = PlaybackController(
            player: player,
            library: store,
            waveformSampler: { _ in [0.2, 0.4] }
        )

        let loadTask = Task {
            try? await controller.loadPreview(url: previewURL, duration: 30)
        }
        await waitForControlledLoad { player.pendingLoadCount == 1 }

        await controller.stop()
        player.completeOldestLoad(duration: 30)
        await loadTask.value
        await controller.play()

        #expect(controller.selectedRecordingID == nil)
        #expect(controller.waveformPeaks.isEmpty)
        #expect(player.playCallCount == 0)
        #expect(!controller.isPlaying)
    }

    @Test("new recording load ignores older preview completion")
    func newRecordingLoadIgnoresOlderPreviewCompletion() async throws {
        let paths = LibraryPaths(libraryRoot: uniquePlaybackControllerLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let player = ControlledLoadPlayerEngine()
        let previewURL = paths.libraryRoot.appending(path: "preview.m4a")
        let recording = Recording(title: "Selected", duration: 12, mode: .micOnly)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
        try store.add(recording)
        let controller = PlaybackController(
            player: player,
            library: store,
            waveformSampler: { url in
                url == previewURL ? [0.1] : [0.9]
            }
        )

        let previewTask = Task {
            try? await controller.loadPreview(url: previewURL, duration: 30)
        }
        await waitForControlledLoad { player.pendingLoadCount == 1 }
        let recordingTask = Task {
            try? await controller.load(recording: recording)
        }
        await waitForControlledLoad { player.pendingLoadCount == 2 }

        player.completeOldestLoad(duration: 30)
        await previewTask.value
        player.completeOldestLoad(duration: 12)
        await recordingTask.value
        await waitForPlaybackState { controller.waveformPeaks == [0.9] }

        #expect(controller.selectedRecordingID == recording.id)
        #expect(controller.duration == 12)
        #expect(controller.waveformPeaks == [0.9])
    }

    @Test("new recording load ignores older detached waveform sampling")
    func newRecordingLoadIgnoresOlderDetachedWaveformSampling() async throws {
        let paths = LibraryPaths(libraryRoot: uniquePlaybackControllerLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let player = FakePlayerEngine()
        let previewURL = paths.libraryRoot.appending(path: "preview.m4a")
        let recording = Recording(title: "Selected", duration: 12, mode: .micOnly)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
        try store.add(recording)
        let sampler = DelayedWaveformSampler(peaks: [
            previewURL: [0.1],
            paths.audioURL(for: recording.id): [0.9]
        ])
        let controller = PlaybackController(
            player: player,
            library: store,
            waveformSampler: sampler.sample(url:)
        )

        try await controller.loadPreview(url: previewURL, duration: 30)
        await waitForDetachedSampler { sampler.callCount == 1 }
        try await controller.load(recording: recording)
        await waitForDetachedSampler { sampler.callCount == 2 }
        await waitForPlaybackState { controller.waveformPeaks == [0.9] }
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(controller.selectedRecordingID == recording.id)
        #expect(controller.waveformPeaks == [0.9])
    }
}

@MainActor
private struct PlaybackControllerHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let player: FakePlayerEngine
    let controller: PlaybackController

    static func make() async -> PlaybackControllerHarness {
        let paths = LibraryPaths(libraryRoot: uniquePlaybackControllerLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let player = FakePlayerEngine()
        let controller = PlaybackController(player: player, library: store)
        return PlaybackControllerHarness(paths: paths, store: store, player: player, controller: controller)
    }

    func addRecording(duration: TimeInterval) async throws -> Recording {
        let recording = Recording(title: "Test Recording", duration: duration, mode: .micOnly)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
        try store.add(recording)
        return recording
    }
}

private func uniquePlaybackControllerLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerPlaybackControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private final class DelayedWaveformSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let peaks: [URL: [Double]]
    private var sampleCallCount = 0

    var callCount: Int {
        lock.withLock {
            sampleCallCount
        }
    }

    init(peaks: [URL: [Double]]) {
        self.peaks = peaks
    }

    func sample(url: URL) -> [Double] {
        let count = lock.withLock {
            sampleCallCount += 1
            return sampleCallCount
        }
        if count == 1 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return peaks[url] ?? []
    }
}

@MainActor
private final class ControlledLoadPlayerEngine: PlayerEngine {
    private struct PendingLoad {
        let continuation: CheckedContinuation<Void, any Error>
    }

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var playCallCount = 0
    private(set) var loadedURLs: [URL] = []
    private(set) var seekRequests: [TimeInterval] = []
    private var pendingLoads: [PendingLoad] = []
    private var finishHandler: (@MainActor () -> Void)?

    var pendingLoadCount: Int { pendingLoads.count }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        finishHandler = handler
    }

    func load(url: URL) async throws {
        loadedURLs.append(url)
        try await withCheckedThrowingContinuation { continuation in
            pendingLoads.append(PendingLoad(continuation: continuation))
        }
    }

    func completeOldestLoad(duration: TimeInterval) {
        guard !pendingLoads.isEmpty else { return }
        self.duration = duration
        let load = pendingLoads.removeFirst()
        load.continuation.resume()
    }

    func play() async throws {
        playCallCount += 1
        isPlaying = true
    }

    func pause() async {
        pauseCallCount += 1
        isPlaying = false
    }

    func seek(to time: TimeInterval) async {
        seekRequests.append(time)
        currentTime = time
    }

    func stop() async {
        stopCallCount += 1
        isPlaying = false
        currentTime = 0
    }
}

@MainActor
private func waitForControlledLoad(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        await Task.yield()
    }
}

@MainActor
private func waitForPlaybackState(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        await Task.yield()
    }
}

private func waitForDetachedSampler(_ condition: @escaping @Sendable () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
