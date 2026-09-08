import AudioPipeline
import Foundation

protocol AudioPipelineCaptureSessioning: Actor {
    func terminalEvents() -> AsyncStream<CaptureTerminalEvent>
    func start(configuration: RecordingConfiguration) async throws -> CaptureStartResult
    func pause() async throws -> RecordingSegmentOutput
    func resume(outputURL: URL) async throws
    func stop() async throws -> FinishedRecordingOutput
    func hasPendingCleanup() -> Bool
    func progress() -> CaptureProgress?
}

extension AudioPipelineCaptureSessioning {
    func progress() -> CaptureProgress? {
        nil
    }
}

extension CaptureSession: AudioPipelineCaptureSessioning {
    func terminalEvents() -> AsyncStream<CaptureTerminalEvent> {
        terminalEventStream
    }
}

@MainActor
final class AudioPipelineRecorderEngine: RecorderEngine {
    private struct ActiveSegmentCapture {
        let audioURL: URL
        let segmentsDirectoryURL: URL
        let previewURL: URL
        var segments: [URL]
        var nextSegmentIndex: Int
    }

    private(set) var state: RecorderState = .idle
    private var captureSession: (any AudioPipelineCaptureSessioning)?
    private var activeCapture: ActiveSegmentCapture?
    private var publishableSegmentsDirectoryURL: URL?
    private var eventConsumerTask: Task<Void, Never>?
    private var progressPollTask: Task<Void, Never>?
    private var activeRecordingID: UUID?
    private let makeCaptureSession: @MainActor () -> any AudioPipelineCaptureSessioning
    private let merger: AudioSegmentMerger
    private let stream: AsyncStream<RecorderEvent>
    private let continuation: AsyncStream<RecorderEvent>.Continuation

    var events: AsyncStream<RecorderEvent> { stream }
    var liveAudioHandler: LiveAudioSampleHandler?

    init(
        makeCaptureSession: @escaping @MainActor () -> any AudioPipelineCaptureSessioning = { CaptureSession() },
        merger: AudioSegmentMerger? = nil
    ) {
        self.makeCaptureSession = makeCaptureSession
        self.merger = merger ?? AudioSegmentMerger()
        var capturedContinuation: AsyncStream<RecorderEvent>.Continuation!
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func supportsLiveAudioObservation(for mode: CaptureMode) -> Bool {
        true
    }

    func start(_ request: RecorderRequest) async throws -> RecorderStart {
        try await finishPendingCleanupBeforeStart()
        let session = makeCaptureSession()
        captureSession = session
        activeRecordingID = request.id
        let segmentsDirectoryURL = request.directoryURL.appending(path: "segments", directoryHint: .isDirectory)
        let firstSegmentURL = segmentsDirectoryURL.appending(path: "000.m4a")
        do {
            try FileManager.default.createDirectory(at: segmentsDirectoryURL, withIntermediateDirectories: true)
            let result = try await session.start(configuration: RecordingConfiguration(
                mode: request.mode,
                microphoneUID: request.microphoneUID,
                outputURL: firstSegmentURL,
                microphoneGain: request.microphoneGain,
                systemGain: request.systemGain,
                liveAudioHandler: liveAudioHandler
            ))
            activeCapture = ActiveSegmentCapture(
                audioURL: request.directoryURL.appending(path: "audio.m4a"),
                segmentsDirectoryURL: segmentsDirectoryURL,
                previewURL: segmentsDirectoryURL.appending(path: "preview.m4a"),
                segments: [],
                nextSegmentIndex: 1
            )
            startEventConsumer(for: session, recordingID: request.id)
            startProgressPolling(for: session, recordingID: request.id)
            state = .recording
            return RecorderStart(warnings: result.warnings.map(Self.warningDescription))
        } catch {
            state = .idle
            activeCapture = nil
            activeRecordingID = nil
            stopProgressPolling()
            if await !session.hasPendingCleanup() {
                captureSession = nil
            }
            throw mapError(error)
        }
    }

    func pause() async throws -> RecorderPreview {
        guard state == .recording, let captureSession, var capture = activeCapture else {
            throw RecorderEngineError.pauseUnavailable
        }
        do {
            let segment = try await captureSession.pause()
            capture.segments.append(segment.url)
            activeCapture = capture
            state = .paused
            if capture.segments.count == 1 {
                return RecorderPreview(url: segment.url, duration: segment.duration)
            }
            let preview = try await replacePreview(for: capture)
            return RecorderPreview(url: preview.url, duration: preview.duration)
        } catch {
            state = .idle
            stopProgressPolling()
            if let activeRecordingID {
                yieldFailure(for: error, recordingID: activeRecordingID)
            }
            throw mapError(error)
        }
    }

    func resume() async throws {
        guard state == .paused, let captureSession, var capture = activeCapture else {
            throw RecorderEngineError.pauseUnavailable
        }
        do {
            let nextURL = capture.segmentsDirectoryURL
                .appending(path: String(format: "%03d.m4a", capture.nextSegmentIndex))
            capture.nextSegmentIndex += 1
            try await captureSession.resume(outputURL: nextURL)
            activeCapture = capture
            state = .recording
        } catch {
            state = .idle
            stopProgressPolling()
            if let activeRecordingID {
                yieldFailure(for: error, recordingID: activeRecordingID)
            }
            throw mapError(error)
        }
    }

    func stop() async throws -> RecorderResult {
        guard let captureSession else {
            throw RecorderEngineError.failed(message: "Recording has not started", settingsURL: nil, keepsPartialFile: false)
        }
        guard var capture = activeCapture else {
            throw RecorderEngineError.failed(message: "Recording segment state is unavailable", settingsURL: nil, keepsPartialFile: false)
        }

        do {
            let output = try await captureSession.stop()
            if state == .recording {
                capture.segments.append(output.url)
            }
            let merged = try await merger.merge(capture.segments, to: capture.audioURL)
            self.captureSession = nil
            activeCapture = nil
            publishableSegmentsDirectoryURL = capture.segmentsDirectoryURL
            activeRecordingID = nil
            stopEventConsumer()
            stopProgressPolling()
            state = .stopped
            return RecorderResult(
                url: merged.url,
                duration: merged.duration,
                warnings: output.warnings.map(Self.warningDescription)
            )
        } catch {
            let failedRecordingID = activeRecordingID
            if await !captureSession.hasPendingCleanup() {
                self.captureSession = nil
            }
            activeCapture = nil
            activeRecordingID = nil
            stopEventConsumer()
            stopProgressPolling()
            state = .idle
            if let failedRecordingID {
                yieldFailure(for: error, recordingID: failedRecordingID)
            }
            throw mapError(error)
        }
    }

    func confirmPublished() async {
        if let publishableSegmentsDirectoryURL {
            try? FileManager.default.removeItem(at: publishableSegmentsDirectoryURL)
            self.publishableSegmentsDirectoryURL = nil
        }
    }

    private func finishPendingCleanupBeforeStart() async throws {
        guard let captureSession else { return }
        guard await captureSession.hasPendingCleanup() else {
            self.captureSession = nil
            activeCapture = nil
            activeRecordingID = nil
            stopEventConsumer()
            stopProgressPolling()
            state = .idle
            return
        }

        do {
            _ = try await captureSession.stop()
            self.captureSession = nil
            activeCapture = nil
            activeRecordingID = nil
            stopEventConsumer()
            stopProgressPolling()
            state = .idle
        } catch {
            let failedRecordingID = activeRecordingID
            if await !captureSession.hasPendingCleanup() {
                self.captureSession = nil
            }
            activeCapture = nil
            activeRecordingID = nil
            stopEventConsumer()
            stopProgressPolling()
            state = .idle
            if let failedRecordingID {
                yieldFailure(for: error, recordingID: failedRecordingID)
            }
            throw mapError(error)
        }
    }

    private func yieldFailure(for error: Error, recordingID: UUID) {
        let mapped = mapError(error)
        continuation.yield(.recordingFailed(
            recordingID: recordingID,
            message: mapped.message,
            settingsURL: mapped.settingsURL,
            keepsPartialFile: mapped.keepsPartialFile
        ))
    }

    private func startEventConsumer(for session: any AudioPipelineCaptureSessioning, recordingID: UUID) {
        stopEventConsumer()
        eventConsumerTask = Task { [weak self] in
            let events = await session.terminalEvents()
            for await event in events {
                await self?.handleTerminalEvent(event, recordingID: recordingID, session: session)
            }
        }
    }

    private func handleTerminalEvent(
        _ event: CaptureTerminalEvent,
        recordingID: UUID,
        session: any AudioPipelineCaptureSessioning
    ) async {
        guard activeRecordingID == recordingID else { return }
        activeCapture = nil
        activeRecordingID = nil
        state = .idle
        yieldFailure(for: event.error, recordingID: recordingID)
        if await !session.hasPendingCleanup() {
            captureSession = nil
        }
        stopEventConsumer()
        stopProgressPolling()
    }

    private func stopEventConsumer() {
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
    }

    private func startProgressPolling(
        for session: any AudioPipelineCaptureSessioning,
        recordingID: UUID
    ) {
        stopProgressPolling()
        progressPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let progress = await session.progress() {
                    self?.yieldProgress(progress, recordingID: recordingID)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func yieldProgress(_ progress: CaptureProgress, recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        continuation.yield(.levels(recordingID: recordingID, progress: progress))
    }

    private func stopProgressPolling() {
        progressPollTask?.cancel()
        progressPollTask = nil
    }

    private func replacePreview(for capture: ActiveSegmentCapture) async throws -> RecorderPreview {
        let temporaryURL = capture.segmentsDirectoryURL
            .appending(path: ".preview.\(UUID().uuidString).m4a")
        do {
            let preview = try await merger.merge(capture.segments, to: temporaryURL)
            if FileManager.default.fileExists(atPath: capture.previewURL.path) {
                _ = try FileManager.default.replaceItemAt(capture.previewURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: capture.previewURL)
            }
            return RecorderPreview(
                url: capture.previewURL,
                duration: preview.duration
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func mapError(_ error: Error) -> RecorderEngineError {
        if let recorderError = error as? RecorderEngineError {
            return recorderError
        }
        if let audioError = error as? AudioCaptureError {
            let message = Self.message(for: audioError)
            switch audioError {
            case .microphonePermissionDenied,
                 .systemAudioPermissionDenied:
                return .permissionDenied(message: message, settingsURL: audioError.settingsURL)
            default:
                return .failed(
                    message: message,
                    settingsURL: audioError.settingsURL,
                    keepsPartialFile: audioError.keepsPartialFile
                )
            }
        }
        return .failed(message: error.localizedDescription, settingsURL: nil, keepsPartialFile: false)
    }

    private static func message(for error: AudioCaptureError) -> String {
        switch error {
        case .unsupportedCaptureMode(let mode):
            return "Capture mode \(mode.rawValue) is not supported."
        case .microphonePermissionDenied:
            return "Microphone access is required to record."
        case .systemAudioPermissionDenied:
            return "System audio access is required to record system sound."
        case .tapCreationFailed(let status):
            return "Could not create the system audio tap. OSStatus \(status)."
        case .aggregateCreationFailed(let status):
            return "Could not create the recording device. OSStatus \(status)."
        case .deviceNotFound:
            return "The selected recording device could not be found."
        case .unsupportedStreamFormat:
            return "The recording device format is not supported."
        case .ioProcCreationFailed(let status):
            return "Could not prepare audio capture. OSStatus \(status)."
        case .startFailed(let status):
            return "Could not start audio capture. OSStatus \(status)."
        case .outputAlreadyExists:
            return "The recording file already exists."
        case .fileWriteFailed(let reason):
            return "Could not write the recording file. \(reason)"
        case .diskSpaceLow:
            return "There is not enough disk space to continue recording."
        case .deviceDisconnected:
            return "A recording device was disconnected."
        case .ioStoppedAbnormally:
            return "Audio capture stopped unexpectedly."
        case .streamFormatChanged:
            return "The recording device format changed during recording."
        }
    }

    private static func warningDescription(_ warning: AudioCaptureWarning) -> String {
        switch warning {
        case .bluetoothInputMayDegradeQuality:
            return "bluetoothInputMayDegradeQuality"
        case .selfExclusionUnavailable:
            return "selfExclusionUnavailable"
        case .framesDropped(let count):
            return "framesDropped(\(count))"
        case .systemAudioWasSilent:
            return "systemAudioWasSilent"
        case .channelOrderAssumed:
            return "channelOrderAssumed"
        }
    }
}
