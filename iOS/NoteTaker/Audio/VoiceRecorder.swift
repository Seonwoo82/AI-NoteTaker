import AVFoundation
#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Foundation
import Observation

@MainActor
protocol VoiceClock: AnyObject {
    var now: Date { get }
}

@MainActor
private final class SystemVoiceClock: VoiceClock {
    var now: Date { Date() }
}

nonisolated struct VoiceRecordingResult: Equatable, Sendable {
    let duration: TimeInterval
    let warnings: [String]
}

@MainActor
protocol VoiceRecordingSession: AnyObject {
    var canPause: Bool { get }

    func pause() throws
    func resume() throws
    func finish() async throws -> VoiceRecordingResult
    func cancel() async
}

@MainActor
protocol VoiceRecordingBackend: AnyObject {
    func makeRecordingID() -> UUID
    func start(
        outputURL: URL,
        mode: CaptureMode,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> any VoiceRecordingSession
}

@MainActor
@Observable
final class VoiceRecorder {
    private enum State {
        case idle
        case starting
        case recording(ActiveRecording)
        case paused(ActiveRecording)
        case finalizing
        case pendingSave(PendingRecording)
    }

    private struct ActiveRecording {
        let id: UUID
        let title: String
        let mode: CaptureMode
        let outputURL: URL
        let createdAt: Date
        let session: any VoiceRecordingSession
        var accumulatedElapsed: TimeInterval
        var currentRunStartedAt: Date
    }

    private struct PendingRecording {
        let id: UUID
        let title: String
        let mode: CaptureMode
        let outputURL: URL
        let createdAt: Date
        let duration: TimeInterval
        let warnings: [String]
    }

    var isRecording = false
    var isPaused = false
    var isBusy = false
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    private(set) var canPause = true
    private(set) var hasPendingRecording = false

    @ObservationIgnored private let backend: any VoiceRecordingBackend
    @ObservationIgnored private let clock: any VoiceClock
    @ObservationIgnored private var state: State = .idle
    @ObservationIgnored private weak var interruptionLibrary: LibraryStore?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    init(
        backend: any VoiceRecordingBackend = PlatformVoiceRecordingBackend(),
        clock: any VoiceClock = SystemVoiceClock()
    ) {
        self.backend = backend
        self.clock = clock
    }

    func start(library: LibraryStore, mode: CaptureMode) async {
        guard case .idle = state else { return }
        isBusy = true
        errorMessage = nil
        elapsed = 0
        hasPendingRecording = false
        state = .starting

        let id = backend.makeRecordingID()
        let outputURL = library.paths.directory(for: id).appending(path: "audio.m4a")
        let title = library.nextTitle()
        let startedAt = clock.now
        interruptionLibrary = library

        do {
            let session = try await backend.start(outputURL: outputURL, mode: mode) { [weak self] in
                guard let self, let library = self.interruptionLibrary else { return }
                _ = await self.finish(library: library)
            }
            let active = ActiveRecording(
                id: id,
                title: title,
                mode: mode,
                outputURL: outputURL,
                createdAt: startedAt,
                session: session,
                accumulatedElapsed: 0,
                currentRunStartedAt: startedAt
            )
            state = .recording(active)
            isRecording = true
            isPaused = false
            isBusy = false
            canPause = session.canPause
            startElapsedClock()
        } catch {
            state = .idle
            isRecording = false
            isPaused = false
            isBusy = false
            canPause = true
            errorMessage = describe(error)
        }
    }

    func pause() {
        guard case var .recording(active) = state else { return }
        guard active.session.canPause else {
            canPause = false
            errorMessage = String(localized: "Pause is not supported for this capture mode.")
            return
        }

        do {
            try active.session.pause()
            active.accumulatedElapsed += max(clock.now.timeIntervalSince(active.currentRunStartedAt), 0)
            state = .paused(active)
            isPaused = true
            stopElapsedClock()
            elapsed = active.accumulatedElapsed
        } catch {
            errorMessage = describe(error)
        }
    }

    func resume() {
        guard case var .paused(active) = state else { return }

        do {
            try active.session.resume()
            active.currentRunStartedAt = clock.now
            state = .recording(active)
            isPaused = false
            startElapsedClock()
        } catch {
            errorMessage = describe(error)
        }
    }

    func finish(library: LibraryStore) async -> Recording? {
        if case let .pendingSave(pending) = state {
            return persist(pending, into: library)
        }

        let active: ActiveRecording
        switch state {
        case let .recording(value), let .paused(value):
            active = value
        default:
            return nil
        }

        state = .finalizing
        isBusy = true
        isRecording = false
        isPaused = false
        stopElapsedClock()

        do {
            let result = try await active.session.finish()
            let pending = PendingRecording(
                id: active.id,
                title: active.title,
                mode: active.mode,
                outputURL: active.outputURL,
                createdAt: active.createdAt,
                duration: result.duration,
                warnings: result.warnings
            )
            return persist(pending, into: library)
        } catch {
            if let pending = pendingFromPlayableAudioAfterFinishError(active: active) {
                state = .pendingSave(pending)
                isBusy = false
                hasPendingRecording = true
                errorMessage = describe(error)
            } else {
                state = .idle
                isBusy = false
                errorMessage = describe(error)
            }
            return nil
        }
    }

    func deferPendingSave() {
        guard case .pendingSave = state else { return }
        state = .idle
        isRecording = false
        isPaused = false
        isBusy = false
        elapsed = 0
        interruptionLibrary = nil
        hasPendingRecording = false
    }

    func recoverRecordings(library: LibraryStore) async -> [Recording] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: library.paths.recordingsRoot,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return [] }

        var recovered: [Recording] = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  library.recording(id: id) == nil,
                  !fileManager.fileExists(atPath: library.paths.metadataURL(for: id).path)
            else { continue }

            let audioURL = library.paths.directory(for: id).appending(path: "audio.m4a")
            guard fileManager.fileExists(atPath: audioURL.path),
                  let duration = playableDuration(at: audioURL)
            else { continue }

            let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let recording = Recording(
                id: id,
                title: library.nextTitle(),
                createdAt: createdAt,
                duration: duration,
                mode: .micOnly,
                warnings: ["Recovered finalized audio without metadata."]
            )

            do {
                try library.add(recording)
                recovered.append(recording)
            } catch {
                errorMessage = describe(error)
            }
        }
        return recovered
    }

    private func persist(_ pending: PendingRecording, into library: LibraryStore) -> Recording? {
        let recording = Recording(
            id: pending.id,
            title: pending.title,
            createdAt: pending.createdAt,
            duration: pending.duration,
            mode: pending.mode,
            warnings: pending.warnings
        )

        do {
            if library.recording(id: recording.id) == nil {
                try library.add(recording)
            } else {
                try library.update(recording)
            }
            state = .idle
            isBusy = false
            errorMessage = nil
            interruptionLibrary = nil
            hasPendingRecording = false
            return recording
        } catch {
            state = .pendingSave(pending)
            isBusy = false
            errorMessage = describe(error)
            hasPendingRecording = true
            return nil
        }
    }

    private func pendingFromPlayableAudioAfterFinishError(active: ActiveRecording) -> PendingRecording? {
        guard let duration = playableDuration(at: active.outputURL) else { return nil }
        return PendingRecording(
            id: active.id,
            title: active.title,
            mode: active.mode,
            outputURL: active.outputURL,
            createdAt: active.createdAt,
            duration: duration > 0 ? duration : max(clock.now.timeIntervalSince(active.createdAt), 0.1),
            warnings: ["Recovered playable audio after finalization error."]
        )
    }

    private func playableDuration(at url: URL) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        if player.duration.isFinite, player.duration > 0 {
            return player.duration
        }
        return nil
    }

    private func startElapsedClock() {
        stopElapsedClock()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refreshElapsed()
                }
            }
        }
    }

    private func stopElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    func refreshElapsed() {
        switch state {
        case let .recording(active):
            elapsed = active.accumulatedElapsed + max(clock.now.timeIntervalSince(active.currentRunStartedAt), 0)
        case let .paused(active):
            elapsed = active.accumulatedElapsed
        default:
            break
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

@MainActor
private final class PlatformVoiceRecordingBackend: VoiceRecordingBackend {
    func makeRecordingID() -> UUID {
        UUID()
    }

    func start(
        outputURL: URL,
        mode: CaptureMode,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> any VoiceRecordingSession {
        #if os(macOS)
        if mode == .systemOnly {
            return try await MacSystemRecordingSession.start(outputURL: outputURL, interruptionHandler: interruptionHandler)
        }
        #endif

        guard mode == .micOnly else {
            throw VoiceRecorderError.unsupportedMode(mode)
        }
        return try await AVFoundationRecordingSession.start(
            outputURL: outputURL,
            interruptionHandler: interruptionHandler
        )
    }
}

nonisolated enum VoiceRecorderError: Error, Equatable, LocalizedError, Sendable {
    case microphonePermissionDenied
    case unsupportedMode(CaptureMode)
    case fileMissingAfterFinish
    case encoderFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return String(localized: "Microphone access is required to record.")
        case let .unsupportedMode(mode):
            return String(localized: "\(mode.rawValue) is not supported on this device.")
        case .fileMissingAfterFinish:
            return String(localized: "The recording could not be finalized.")
        case .encoderFailed:
            return String(localized: "The recording encoder could not finish the audio file.")
        }
    }
}

@MainActor
private final class AVFoundationRecordingSession: NSObject, VoiceRecordingSession, AVAudioRecorderDelegate {
    let canPause = true

    private let recorder: AVAudioRecorder
    private let startedAt: Date
    private let interruptionObserver: NSObjectProtocol?
    private var interruptionHandler: (@MainActor @Sendable () async -> Void)?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var terminalFinishResult: Bool?

    private init(
        recorder: AVAudioRecorder,
        startedAt: Date,
        interruptionObserver: NSObjectProtocol?,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.recorder = recorder
        self.startedAt = startedAt
        self.interruptionObserver = interruptionObserver
        self.interruptionHandler = interruptionHandler
        super.init()
        self.recorder.delegate = self
    }

    static func start(
        outputURL: URL,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> AVFoundationRecordingSession {
        try await prepareAudioSession()
        var observer: NSObjectProtocol?
        var shouldDeactivateSession = true
        defer {
            if shouldDeactivateSession { cleanupFailedStart(observer: observer) }
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        #if os(iOS)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began
            else { return }

            Task { @MainActor in
                await interruptionHandler()
            }
        }
        #endif

        let recorder = try AVAudioRecorder(url: outputURL, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceRecorderError.fileMissingAfterFinish
        }
        shouldDeactivateSession = false

        return AVFoundationRecordingSession(
            recorder: recorder,
            startedAt: Date(),
            interruptionObserver: observer,
            interruptionHandler: interruptionHandler
        )
    }

    func pause() {
        recorder.pause()
    }

    func resume() throws {
        guard recorder.record() else {
            throw VoiceRecorderError.encoderFailed
        }
    }

    func finish() async throws -> VoiceRecordingResult {
        let finishedSuccessfully = await stopAndWaitForFinish()
        cleanup()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        guard finishedSuccessfully else {
            throw VoiceRecorderError.encoderFailed
        }
        guard FileManager.default.fileExists(atPath: recorder.url.path) else {
            throw VoiceRecorderError.fileMissingAfterFinish
        }

        let asset = AVURLAsset(url: recorder.url)
        let duration = try await asset.load(.duration).seconds
        let fallbackDuration = Date().timeIntervalSince(startedAt)
        return VoiceRecordingResult(
            duration: duration.isFinite && duration > 0 ? duration : fallbackDuration,
            warnings: []
        )
    }

    func cancel() async {
        interruptionHandler = nil
        recorder.delegate = nil
        recorder.stop()
        recorder.deleteRecording()
        cleanup()
    }

    private func cleanup() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionHandler = nil
    }

    private static func prepareAudioSession() async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw VoiceRecorderError.microphonePermissionDenied
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #else
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw VoiceRecorderError.microphonePermissionDenied
        }
        #endif
    }

    private static func cleanupFailedStart(observer: NSObjectProtocol?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func stopAndWaitForFinish() async -> Bool {
        if let terminalFinishResult {
            return terminalFinishResult
        }
        return await withCheckedContinuation { continuation in
            if let terminalFinishResult {
                continuation.resume(returning: terminalFinishResult)
            } else {
                finishContinuation = continuation
                recorder.stop()
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.resumeFinish(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.resumeFinish(false)
        }
    }

    private func resumeFinish(_ flag: Bool) {
        guard terminalFinishResult == nil else { return }
        terminalFinishResult = flag

        if let finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(returning: flag)
        } else {
            let interruptionHandler = interruptionHandler
            Task { @MainActor in
                await interruptionHandler?()
            }
        }
    }
}

#if os(macOS) && canImport(AudioPipeline)
@MainActor
private final class MacSystemRecordingSession: VoiceRecordingSession {
    let canPause = false

    private let session: CaptureSession

    private init(session: CaptureSession) {
        self.session = session
    }

    static func start(
        outputURL: URL,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> MacSystemRecordingSession {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let session = CaptureSession()
        _ = try await session.start(configuration: RecordingConfiguration(
            mode: .systemOnly,
            microphoneUID: nil,
            outputURL: outputURL,
            microphoneGain: 1,
            systemGain: 1
        ))
        return MacSystemRecordingSession(session: session)
    }

    func pause() throws {
        throw VoiceRecorderError.unsupportedMode(.systemOnly)
    }

    func resume() throws {
        throw VoiceRecorderError.unsupportedMode(.systemOnly)
    }

    func finish() async throws -> VoiceRecordingResult {
        let output = try await session.stop()
        return VoiceRecordingResult(
            duration: output.duration,
            warnings: output.warnings.map(String.init(describing:))
        )
    }

    func cancel() async {
        _ = try? await session.stop()
    }
}
#endif
