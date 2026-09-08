import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct WaveformLoadingTests {
    @Test("Clearing an empty search restores the same selected recording and its waveform")
    func searchRoundTripRestoresWaveform() async throws {
        let h = try await WaveformHarness.make()
        let model = AppModel()
        model.selectedRecordingID = h.recording.id
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WaveformSearchTests-\(UUID())")!,
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil))
        let session = RecordingSession(recorder: FakeRecorderEngine(), player: h.player,
            library: h.library, appModel: model, settings: settings)
        let controller = LibraryController(library: h.library, model: model, session: session, playback: h.controller)
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()

        controller.setSearchText("no match")
        for _ in 0..<100 {
            if model.selectedRecordingID == nil && h.controller.waveformPeaks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.selectedRecordingID == nil)
        #expect(h.controller.waveformPeaks.isEmpty)
        controller.setSearchText("")
        for _ in 0..<100 {
            if model.selectedRecordingID == h.recording.id { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.selectedRecordingID == h.recording.id)
        try await h.controller.prepareForDisplay(recording: h.recording)
        #expect(h.controller.waveformPeaks == [0.2, 0.8, 0.4])
        #expect(h.sampler.count == 1)
    }

    @Test("Concurrent display requests show loading and share one pending audio load")
    func sharesPendingLoad() async throws {
        let h = try await WaveformHarness.make()
        h.player.suspendNextLoad = true
        let first = Task { try await h.controller.prepareForDisplay(recording: h.recording) }
        for _ in 0..<100 {
            if h.player.loadIsPending { break }
            await Task.yield()
        }
        #expect(h.player.loadIsPending)
        #expect(h.controller.isLoadingWaveform)
        try await h.controller.prepareForDisplay(recording: h.recording)
        #expect(h.player.loadCount == 1)
        h.player.finishLoad()
        try await first.value
        try await h.waitForPeaks()
        #expect(!h.controller.isLoadingWaveform)
    }

    @Test("A failed waveform read is retried on re-entry without resetting loaded audio")
    func retriesEmptySamplingResult() async throws {
        let h = try await WaveformHarness.make(sampler: CountingWaveformSampler(failFirst: true))
        try await h.controller.prepareForDisplay(recording: h.recording)
        for _ in 0..<100 {
            if !h.controller.isLoadingWaveform { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.controller.waveformPeaks.isEmpty)
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        #expect(h.player.loadCount == 1)
        #expect(h.sampler.count == 2)
    }

    @Test("Returning to a stopped selection restores its waveform without pressing Play")
    func restoresStoppedSelection() async throws {
        let h = try await WaveformHarness.make()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        await h.controller.stop()
        #expect(h.controller.waveformPeaks.isEmpty)

        try await h.controller.prepareForDisplay(recording: h.recording)
        #expect(h.controller.waveformPeaks == [0.2, 0.8, 0.4])
        #expect(h.sampler.count == 1, "Returning should reuse completed peaks for this audio version.")
        #expect(!h.controller.isPlaying)
    }

    @Test("Repeated appearance preserves playback position and avoids reloading ready audio")
    func readyAppearanceIsIdempotent() async throws {
        let h = try await WaveformHarness.make()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        await h.controller.seek(to: 7)
        await h.controller.play()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.controller.prepareForDisplay(recording: h.recording)
        #expect(h.controller.currentTime == 7)
        #expect(h.controller.isPlaying)
        #expect(h.player.loadCount == 1)
        #expect(h.sampler.count == 1)
        await h.controller.stop()
    }

    @Test("A changed audio version invalidates the old waveform cache")
    func refreshesChangedAudioVersion() async throws {
        let h = try await WaveformHarness.make()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        var edited = h.recording
        edited.audioVersion += 1
        try h.library.update(edited)
        try await h.controller.prepareForDisplay(recording: edited)
        for _ in 0..<100 {
            if h.sampler.count == 2 && !h.controller.isLoadingWaveform { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.player.loadCount == 2)
        #expect(h.sampler.count == 2)
        #expect(!h.controller.waveformPeaks.isEmpty)
    }

    @Test("Play refreshes changed audio even before the detail appearance task runs")
    func playRefreshesChangedAudioVersion() async throws {
        let h = try await WaveformHarness.make()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        var edited = h.recording
        edited.audioVersion += 1
        try h.library.update(edited)
        await h.controller.play()
        try await h.waitForPeaks()
        #expect(h.player.loadCount == 2)
        #expect(h.sampler.count == 2)
        #expect(h.controller.isPlaying)
        await h.controller.stop()
    }

    @Test("A suspended older stop cannot clear a newer selection's waveform")
    func staleStopCannotClearNewerWaveform() async throws {
        let h = try await WaveformHarness.make()
        try await h.controller.prepareForDisplay(recording: h.recording)
        try await h.waitForPeaks()
        h.player.suspendNextStop = true
        let oldStop = Task { await h.controller.stop() }
        for _ in 0..<100 {
            if h.player.stopIsPending { break }
            await Task.yield()
        }
        #expect(h.player.stopIsPending)
        let next = Recording(title: "Other", duration: 12, mode: .micOnly)
        try h.library.add(next)
        try await h.controller.prepareForDisplay(recording: next)
        try await h.waitForPeaks()
        h.player.finishStop()
        await oldStop.value
        #expect(h.controller.selectedRecordingID == next.id)
        #expect(h.controller.waveformPeaks == [0.2, 0.8, 0.4])
        #expect(!h.controller.isLoadingWaveform)
    }
}

@MainActor
private struct WaveformHarness {
    let recording: Recording
    let library: LibraryStore
    let controller: PlaybackController
    let player: WaveformTestPlayer
    let sampler: CountingWaveformSampler

    static func make(sampler: CountingWaveformSampler = CountingWaveformSampler()) async throws -> WaveformHarness {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerWaveformTests-\(UUID())")
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let recording = Recording(title: "Meeting", duration: 20, mode: .micOnly)
        try library.add(recording)
        let player = WaveformTestPlayer()
        let controller = PlaybackController(player: player, library: library, waveformSampler: sampler.sample)
        return WaveformHarness(recording: recording, library: library, controller: controller, player: player, sampler: sampler)
    }

    func waitForPeaks() async throws {
        for _ in 0..<100 {
            if controller.waveformPeaks == [0.2, 0.8, 0.4] && !controller.isLoadingWaveform { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "WaveformLoadingTests", code: 1)
    }
}

nonisolated private final class CountingWaveformSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var count: Int { lock.withLock { calls } }
    func sample(_ url: URL) -> [Double] {
        let current = lock.withLock { calls += 1; return calls }
        if failFirst && current == 1 { return [] }
        return [0.2, 0.8, 0.4]
    }
}

@MainActor
private final class WaveformTestPlayer: PlayerEngine {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 20
    var loadCount = 0
    var suspendNextStop = false
    var suspendNextLoad = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    var stopIsPending: Bool { stopContinuation != nil }
    var loadIsPending: Bool { loadContinuation != nil }
    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {}
    func load(url: URL) async throws {
        loadCount += 1
        currentTime = 0
        if suspendNextLoad {
            suspendNextLoad = false
            await withCheckedContinuation { loadContinuation = $0 }
        }
    }
    func play() async throws { isPlaying = true }
    func pause() async { isPlaying = false }
    func seek(to time: TimeInterval) async { currentTime = time }
    func stop() async {
        isPlaying = false
        currentTime = 0
        if suspendNextStop {
            suspendNextStop = false
            await withCheckedContinuation { stopContinuation = $0 }
        }
    }
    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
    func finishLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
