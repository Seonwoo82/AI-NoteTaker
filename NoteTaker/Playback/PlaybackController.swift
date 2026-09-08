import AudioPipeline
import Foundation
import Observation

nonisolated struct PlaybackRecordingIdentity: Equatable, Hashable {
    let id: UUID
    let audioVersion: Int

    init(_ recording: Recording) {
        id = recording.id
        audioVersion = recording.audioVersion
    }
}

@MainActor
@Observable
final class PlaybackController {
    private enum LoadedSource: Equatable {
        case recording(PlaybackRecordingIdentity)
        case preview
    }

    private let player: any PlayerEngine
    private let library: LibraryStore
    private let waveformSampler: @Sendable (URL) -> [Double]
    private var pollTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var loadedSource: LoadedSource?
    private var loadGeneration = 0
    private var loadingRecording: PlaybackRecordingIdentity?
    private var cachedWaveform: (source: PlaybackRecordingIdentity, peaks: [Double])?

    private(set) var selectedRecordingID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var waveformPeaks: [Double] = []
    private(set) var isLoadingWaveform = false

    init(
        player: any PlayerEngine,
        library: LibraryStore,
        waveformSampler: @escaping @Sendable (URL) -> [Double] = { WaveformSampler.peaks(from: $0) }
    ) {
        self.player = player
        self.library = library
        self.waveformSampler = waveformSampler
        self.player.setFinishHandler { [weak self] in
            self?.handleFinished()
        }
    }

    func load(recording: Recording) async throws {
        let generation = nextLoadGeneration()
        let source = PlaybackRecordingIdentity(recording)
        loadingRecording = source
        defer {
            if generation == loadGeneration { loadingRecording = nil }
        }
        let wasChangingSelection = selectedRecordingID != nil && selectedRecordingID != recording.id
        selectedRecordingID = recording.id
        loadedSource = nil
        errorMessage = nil
        waveformPeaks = []
        stopWaveformSampling()
        isLoadingWaveform = true
        stopPolling()
        if wasChangingSelection || isPlaying {
            await player.stop()
        }
        guard generation == loadGeneration else { return }
        isPlaying = false
        currentTime = 0
        duration = recording.duration

        do {
            let audioURL = library.audioURL(for: recording)
            try await player.load(url: audioURL)
            guard generation == loadGeneration else { return }
            loadedSource = .recording(source)
            duration = player.duration > 0 ? player.duration : recording.duration
            restoreOrSampleWaveform(url: audioURL, source: source, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = message(for: error)
            isPlaying = false
            isLoadingWaveform = false
            throw error
        }
    }

    func isReadyForDisplay(recording: Recording) -> Bool {
        loadedSource == .recording(PlaybackRecordingIdentity(recording))
    }

    /// Selection is UI identity, not proof that stop() left the audio loaded.
    /// Re-entry must also recover missing peaks without restarting ready playback.
    func prepareForDisplay(recording: Recording) async throws {
        let source = PlaybackRecordingIdentity(recording)
        if isReadyForDisplay(recording: recording) {
            if waveformPeaks.isEmpty && waveformTask == nil {
                restoreOrSampleWaveform(url: library.audioURL(for: recording), source: source, generation: loadGeneration)
            }
            return
        }
        guard loadingRecording != source else { return }
        try await load(recording: recording)
    }

    func loadPreview(url: URL, duration previewDuration: TimeInterval) async throws {
        let generation = nextLoadGeneration()
        loadingRecording = nil
        selectedRecordingID = nil
        loadedSource = nil
        errorMessage = nil
        waveformPeaks = []
        stopWaveformSampling()
        isLoadingWaveform = true
        stopPolling()
        if isPlaying {
            await player.stop()
        }
        guard generation == loadGeneration else { return }
        isPlaying = false
        currentTime = 0
        duration = previewDuration

        do {
            try await player.load(url: url)
            guard generation == loadGeneration else { return }
            loadedSource = .preview
            duration = player.duration > 0 ? player.duration : previewDuration
            startWaveformSampling(url: url, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = message(for: error)
            isPlaying = false
            isLoadingWaveform = false
            throw error
        }
    }

    func play() async {
        guard await ensureSelectedRecordingLoadedIfNeeded() else { return }
        errorMessage = nil
        let timeline = PlaybackTimeline(duration: duration)
        if currentTime >= timeline.endTime {
            await seek(to: 0)
        }
        do {
            try await player.play()
            isPlaying = player.isPlaying
            currentTime = player.currentTime
            startPolling()
        } catch {
            isPlaying = false
            errorMessage = message(for: error)
        }
    }

    private func ensureSelectedRecordingLoadedIfNeeded() async -> Bool {
        guard !canTransport else { return true }
        guard let selectedRecordingID,
              let recording = library.recording(id: selectedRecordingID)
        else {
            return false
        }
        do {
            try await prepareForDisplay(recording: recording)
            return canTransport
        } catch {
            return false
        }
    }

    func pause() async {
        guard canTransport else { return }
        await player.pause()
        currentTime = PlaybackTimeline(duration: duration).clampedSeekTime(player.currentTime)
        isPlaying = false
        stopPolling()
    }

    func togglePlayPause() async {
        if isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    func seek(to time: TimeInterval) async {
        guard canTransport else { return }
        let clamped = PlaybackTimeline(duration: duration).clampedSeekTime(time)
        currentTime = clamped
        await player.seek(to: clamped)
    }

    func skipBackward() async {
        await seek(to: PlaybackTimeline(duration: duration).skippingBackward(from: currentTime))
    }

    func skipForward() async {
        await seek(to: PlaybackTimeline(duration: duration).skippingForward(from: currentTime))
    }

    func stop() async {
        loadGeneration += 1
        loadingRecording = nil
        loadedSource = nil
        isPlaying = false
        currentTime = 0
        waveformPeaks = []
        stopWaveformSampling()
        stopPolling()
        // Invalidate before the suspension. A delayed older stop must not erase
        // a newer selection or cancel its in-flight waveform sampler.
        await player.stop()
    }

    private func handleFinished() {
        currentTime = PlaybackTimeline(duration: duration).endTime
        isPlaying = false
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_333_333)
                guard !Task.isCancelled else { return }
                self?.refreshFromPlayer()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func restoreOrSampleWaveform(url: URL, source: PlaybackRecordingIdentity, generation: Int) {
        if let cachedWaveform, cachedWaveform.source == source {
            waveformPeaks = cachedWaveform.peaks
            isLoadingWaveform = false
        } else {
            startWaveformSampling(url: url, generation: generation, source: source)
        }
    }

    private func startWaveformSampling(url: URL, generation: Int, source: PlaybackRecordingIdentity? = nil) {
        stopWaveformSampling()
        isLoadingWaveform = true
        let waveformSampler = waveformSampler
        waveformTask = Task { [weak self] in
            let samplingTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return [Double]() }
                let peaks = waveformSampler(url)
                guard !Task.isCancelled else { return [Double]() }
                return peaks
            }
            let peaks = await withTaskCancellationHandler {
                await samplingTask.value
            } onCancel: {
                samplingTask.cancel()
            }
            guard !Task.isCancelled else { return }
            guard let self, generation == self.loadGeneration else { return }
            self.waveformPeaks = peaks
            if let source, !peaks.isEmpty {
                // Only the last completed recording is retained; preview files
                // are rewritten on pause and deliberately never cached here.
                self.cachedWaveform = (source, peaks)
            }
            self.waveformTask = nil
            self.isLoadingWaveform = false
        }
    }

    private func stopWaveformSampling() {
        waveformTask?.cancel()
        waveformTask = nil
        isLoadingWaveform = false
    }

    private func nextLoadGeneration() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    private func refreshFromPlayer() {
        guard canTransport else {
            isPlaying = false
            stopPolling()
            return
        }
        currentTime = PlaybackTimeline(duration: duration).clampedSeekTime(player.currentTime)
        isPlaying = player.isPlaying
        if !isPlaying {
            stopPolling()
        }
    }

    private var canTransport: Bool {
        switch loadedSource {
        case .preview:
            return true
        case .recording(let source):
            return selectedRecordingID == source.id
                && library.recording(id: source.id)?.audioVersion == source.audioVersion
        case nil:
            return false
        }
    }

    private func message(for error: Error) -> String {
        if let playerError = error as? PlayerEngineError {
            return playerError.message
        }
        return error.localizedDescription
    }
}
