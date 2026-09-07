import AudioPipeline
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    private enum LoadedSource: Equatable {
        case recording(UUID)
        case preview
    }

    private let player: any PlayerEngine
    private let library: LibraryStore
    private let waveformSampler: @Sendable (URL) -> [Double]
    private var pollTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var loadedSource: LoadedSource?
    private var loadGeneration = 0

    private(set) var selectedRecordingID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var waveformPeaks: [Double] = []

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
        let wasChangingSelection = selectedRecordingID != nil && selectedRecordingID != recording.id
        selectedRecordingID = recording.id
        loadedSource = nil
        errorMessage = nil
        waveformPeaks = []
        stopWaveformSampling()
        stopPolling()
        if wasChangingSelection || isPlaying {
            await player.stop()
        }
        isPlaying = false
        currentTime = 0
        duration = recording.duration

        do {
            let audioURL = library.paths.audioURL(for: recording.id)
            try await player.load(url: audioURL)
            guard generation == loadGeneration else { return }
            loadedSource = .recording(recording.id)
            duration = player.duration > 0 ? player.duration : recording.duration
            startWaveformSampling(url: audioURL, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = message(for: error)
            isPlaying = false
            throw error
        }
    }

    func loadPreview(url: URL, duration previewDuration: TimeInterval) async throws {
        let generation = nextLoadGeneration()
        selectedRecordingID = nil
        loadedSource = nil
        errorMessage = nil
        waveformPeaks = []
        stopWaveformSampling()
        stopPolling()
        if isPlaying {
            await player.stop()
        }
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
            throw error
        }
    }

    func play() async {
        guard canTransport else { return }
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
        await player.stop()
        loadedSource = nil
        isPlaying = false
        currentTime = 0
        waveformPeaks = []
        stopWaveformSampling()
        stopPolling()
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

    private func startWaveformSampling(url: URL, generation: Int) {
        stopWaveformSampling()
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
            self.waveformTask = nil
        }
    }

    private func stopWaveformSampling() {
        waveformTask?.cancel()
        waveformTask = nil
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
        case .recording(let id):
            return selectedRecordingID == id
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
