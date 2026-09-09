import AudioPipeline
import Foundation
import Observation

@MainActor
enum RecordingSessionPhase: Equatable {
    case idle
    case preparing
    case recording
    case pausing
    case paused
    case resuming
    case finishing
}

nonisolated struct RecordingSessionAlert: Equatable, Sendable {
    let message: String
    let settingsURL: URL?
    let keepsPartialFile: Bool

    var displayMessage: String {
        guard keepsPartialFile else { return message }
        return "\(message)\n\n\(String(localized: "Your partial recording file was kept. You can retry finishing or recover it on the next launch."))"
    }
}

@MainActor
@Observable
final class RecordingSession {
    private struct ActiveRecording {
        let id: UUID
        let title: String
        let directoryURL: URL
        let folderID: UUID?
        var accumulatedElapsed: TimeInterval
        var resumedAt: Date
        var warnings: [String]
    }

    private let recorder: any RecorderEngine
    private let library: LibraryStore
    private let appModel: AppModel
    private let settings: AppSettings
    private let stopPlayback: () async -> Void
    private let loadPreview: (URL, TimeInterval) async throws -> Void
    private let onRecordingSaved: (Recording) -> Void
    private let now: () -> Date
    private var activeRecording: ActiveRecording?
    private var eventConsumerTask: Task<Void, Never>?
    private var acceptsNewStarts = true
    private var transitionGeneration = 0

    private(set) var phase: RecordingSessionPhase = .idle
    private(set) var alert: RecordingSessionAlert?
    private(set) var microphonePeak: Float = 0
    private(set) var systemPeak: Float = 0

    init(
        recorder: any RecorderEngine,
        player: any PlayerEngine,
        library: LibraryStore,
        appModel: AppModel,
        settings: AppSettings,
        stopPlayback: (() async -> Void)? = nil,
        loadPreview: (((URL, TimeInterval) async throws -> Void))? = nil,
        now: @escaping () -> Date = Date.init,
        onRecordingSaved: @escaping (Recording) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.library = library
        self.appModel = appModel
        self.settings = settings
        self.stopPlayback = stopPlayback ?? {
            await player.stop()
        }
        self.loadPreview = loadPreview ?? { url, duration in
            try await player.load(url: url)
            _ = duration
        }
        self.now = now
        self.onRecordingSaved = onRecordingSaved
    }

    func start() async {
        guard acceptsNewStarts, phase == .idle else { return }

        let generation = nextTransitionGeneration()
        let selectedFolderID = appModel.selectedCustomFolderID
        phase = .preparing
        alert = nil
        resetLevels()
        await stopPlayback()
        guard isCurrentStartTransition(generation) else { return }

        let id = UUID()
        let directoryURL = library.paths.directory(for: id)
        let title = library.nextTitle()

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let start = try await recorder.start(RecorderRequest(
                id: id,
                directoryURL: directoryURL,
                mode: settings.captureMode,
                microphoneUID: settings.microphoneUID,
                microphoneGain: settings.microphoneGain,
                systemGain: settings.systemGain
            ))
            guard isCurrentStartTransition(generation) else { return }
            activeRecording = ActiveRecording(
                id: id,
                title: title,
                directoryURL: directoryURL,
                folderID: selectedFolderID,
                accumulatedElapsed: 0,
                resumedAt: now(),
                warnings: start.warnings
            )
            startEventConsumer(recordingID: id)
            phase = .recording
        } catch {
            guard isCurrentStartTransition(generation) else { return }
            removeEmptyDirectory(at: directoryURL)
            activeRecording = nil
            stopEventConsumer()
            resetLevels()
            alert = alertValue(for: error)
            phase = .idle
        }
    }

    func pause() async {
        guard phase == .recording, var activeRecording else { return }

        let generation = nextTransitionGeneration()
        let recordingID = activeRecording.id
        phase = .pausing
        let pausedAt = now()
        do {
            let preview = try await recorder.pause()
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .pausing) else { return }
            activeRecording.accumulatedElapsed += max(0, pausedAt.timeIntervalSince(activeRecording.resumedAt))
            activeRecording.resumedAt = pausedAt
            self.activeRecording = activeRecording
            do {
                try await loadPreview(preview.url, preview.duration)
            } catch {
                guard isCurrentTransition(generation, recordingID: recordingID, phase: .pausing) else { return }
                alert = alertValue(for: error)
            }
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .pausing) else { return }
            phase = .paused
        } catch {
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .pausing) else { return }
            alert = alertValue(for: error)
            self.activeRecording = nil
            stopEventConsumer()
            resetLevels()
            phase = .idle
        }
    }

    func resume() async {
        guard phase == .paused, var activeRecording else { return }

        let generation = nextTransitionGeneration()
        let recordingID = activeRecording.id
        phase = .resuming
        await stopPlayback()
        guard isCurrentTransition(generation, recordingID: recordingID, phase: .resuming) else { return }
        do {
            try await recorder.resume()
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .resuming) else { return }
            activeRecording.resumedAt = now()
            self.activeRecording = activeRecording
            phase = .recording
        } catch {
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .resuming) else { return }
            alert = alertValue(for: error)
            self.activeRecording = nil
            stopEventConsumer()
            resetLevels()
            phase = .idle
        }
    }

    func finish() async {
        guard phase == .recording || phase == .paused else { return }
        guard let activeRecording else { return }

        let generation = nextTransitionGeneration()
        let recordingID = activeRecording.id
        phase = .finishing
        do {
            let result = try await recorder.stop()
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .finishing) else { return }
            let expectedAudioURL = library.paths.audioURL(for: activeRecording.id)
            guard result.url == expectedAudioURL,
                  FileManager.default.fileExists(atPath: expectedAudioURL.path) else {
                throw RecorderEngineError.failed(
                    message: "Recording audio was not created.",
                    settingsURL: nil,
                    keepsPartialFile: false
                )
            }
            var recording = Recording(
                id: activeRecording.id,
                title: activeRecording.title,
                createdAt: Date(),
                duration: result.duration,
                mode: settings.captureMode,
                warnings: activeRecording.warnings + result.warnings
            )
            if let folderID = activeRecording.folderID, library.folderStore.isActive(id: folderID) {
                recording.folderID = folderID
                appModel.selectedCustomFolderID = folderID
            } else {
                appModel.selectedCustomFolderID = nil
                appModel.selectedFolder = .all
            }
            try library.add(recording)
            appModel.selectedRecordingID = recording.id
            await recorder.confirmPublished()
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .finishing) else { return }
            self.activeRecording = nil
            stopEventConsumer()
            resetLevels()
            phase = .idle
            onRecordingSaved(recording)
        } catch {
            guard isCurrentTransition(generation, recordingID: recordingID, phase: .finishing) else { return }
            alert = alertValue(for: error)
            self.activeRecording = nil
            stopEventConsumer()
            resetLevels()
            phase = .idle
        }
    }

    func finishForTermination() async {
        acceptsNewStarts = false
        while true {
            switch phase {
            case .idle:
                return
            case .recording, .paused:
                await finish()
            case .preparing, .pausing, .resuming, .finishing:
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func dismissAlert() {
        alert = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let activeRecording else { return 0 }
        switch phase {
        case .idle, .preparing:
            return 0
        case .recording, .resuming, .finishing:
            return max(
                0,
                activeRecording.accumulatedElapsed
                    + date.timeIntervalSince(activeRecording.resumedAt)
            )
        case .pausing, .paused:
            return activeRecording.accumulatedElapsed
        }
    }

    private func alertValue(for error: Error) -> RecordingSessionAlert {
        if let recorderError = error as? RecorderEngineError {
            return RecordingSessionAlert(
                message: recorderError.message,
                settingsURL: recorderError.settingsURL,
                keepsPartialFile: recorderError.keepsPartialFile
            )
        }
        if let playerError = error as? PlayerEngineError {
            return RecordingSessionAlert(
                message: playerError.message,
                settingsURL: nil,
                keepsPartialFile: false
            )
        }
        return RecordingSessionAlert(
            message: error.localizedDescription,
            settingsURL: nil,
            keepsPartialFile: false
        )
    }

    private func nextTransitionGeneration() -> Int {
        transitionGeneration += 1
        return transitionGeneration
    }

    private func invalidateTransitions() {
        transitionGeneration += 1
    }

    private func isCurrentStartTransition(_ generation: Int) -> Bool {
        transitionGeneration == generation
            && phase == .preparing
            && activeRecording == nil
    }

    private func isCurrentTransition(
        _ generation: Int,
        recordingID: UUID,
        phase expectedPhase: RecordingSessionPhase
    ) -> Bool {
        transitionGeneration == generation
            && phase == expectedPhase
            && activeRecording?.id == recordingID
    }

    private func startEventConsumer(recordingID: UUID) {
        stopEventConsumer()
        eventConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await event in recorder.events {
                handleRecorderEvent(event, recordingID: recordingID)
            }
        }
    }

    private func handleRecorderEvent(_ event: RecorderEvent, recordingID: UUID) {
        switch event {
        case .recordingFailed(let eventRecordingID, let message, let settingsURL, let keepsPartialFile):
            guard eventRecordingID == recordingID,
                  activeRecording?.id == eventRecordingID else { return }
            failActiveRecording(message: message, settingsURL: settingsURL, keepsPartialFile: keepsPartialFile)
        case .levels(let eventRecordingID, let progress):
            guard eventRecordingID == recordingID,
                  activeRecording?.id == eventRecordingID else { return }
            updateLevels(progress)
        }
    }

    private func failActiveRecording(message: String, settingsURL: URL?, keepsPartialFile: Bool) {
        guard activeRecording != nil else { return }
        invalidateTransitions()
        activeRecording = nil
        resetLevels()
        alert = RecordingSessionAlert(
            message: message,
            settingsURL: settingsURL,
            keepsPartialFile: keepsPartialFile
        )
        phase = .idle
        stopEventConsumer()
    }

    private func updateLevels(_ progress: CaptureProgress) {
        guard var activeRecording else { return }
        microphonePeak = progress.microphonePeak
        systemPeak = progress.systemPeak
        let duration = max(0, progress.duration)
        if duration >= activeRecording.accumulatedElapsed {
            activeRecording.accumulatedElapsed = duration
            activeRecording.resumedAt = now()
            self.activeRecording = activeRecording
        }
    }

    private func resetLevels() {
        microphonePeak = 0
        systemPeak = 0
    }

    private func stopEventConsumer() {
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
    }

    private func removeEmptyDirectory(at directoryURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
