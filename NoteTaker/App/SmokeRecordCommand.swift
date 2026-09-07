import AppKit
import AudioPipeline
import Darwin
import Foundation

nonisolated enum SmokeRecordArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingDuration
    case invalidDuration(String)
    case durationExceedsMaximum(String, maximum: TimeInterval)
    case missingOutput
    case outputPathMustBeAbsolute(String)
    case outputPathMustBeStandardized(String)
    case outputPathMustNotBeRoot
    case outputPathMustBeFile(String)
    case missingRunToken
    case invalidRunToken(String)
    case missingModeFlag
    case missingMode
    case unknownMode(String)
    case unsupportedMode(CaptureMode)
    case missingClockSource
    case unknownClockSource(String)
    case unexpectedArgument(String)

    static let maximumDuration: TimeInterval = 60 * 60

    var description: String {
        switch self {
        case .missingDuration:
            "missing duration after --smoke-record"
        case .invalidDuration(let value):
            "invalid smoke duration: \(value)"
        case .durationExceedsMaximum(let value, let maximum):
            "smoke duration exceeds maximum: \(value) > \(maximum)"
        case .missingOutput:
            "missing output path after smoke duration"
        case .outputPathMustBeAbsolute(let path):
            "smoke output path must be absolute: \(path)"
        case .outputPathMustBeStandardized(let path):
            "smoke output path must be standardized: \(path)"
        case .outputPathMustNotBeRoot:
            "smoke output path must not be /"
        case .outputPathMustBeFile(let path):
            "smoke output path must name a file: \(path)"
        case .missingRunToken:
            "missing smoke run token"
        case .invalidRunToken(let value):
            "invalid smoke run token: \(value)"
        case .missingModeFlag:
            "missing --mode flag"
        case .missingMode:
            "missing mode after --mode"
        case .unknownMode(let value):
            "unknown smoke mode: \(value)"
        case .unsupportedMode(let mode):
            "unsupported M1c smoke mode: \(mode.rawValue)"
        case .missingClockSource:
            "missing clock source after --clock"
        case .unknownClockSource(let value):
            "unknown smoke clock source: \(value)"
        case .unexpectedArgument(let value):
            "unexpected smoke argument: \(value)"
        }
    }
}

nonisolated struct SmokeRecordRunToken: Equatable, Sendable, RawRepresentable {
    let rawValue: String

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString
    }

    init?(rawValue: String) {
        guard rawValue.utf8.count == 36,
              let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    var data: Data {
        Data(rawValue.utf8)
    }

    func matches(contentsOf url: URL, fileManager: FileManager = .default) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              SmokeRecordPathEntry.exists(at: url, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else {
            return false
        }
        return data == self.data
    }
}

nonisolated struct SmokeRecordArguments: Equatable, Sendable {
    static let runTokenEnvironmentKey = "NOTE_TAKER_SMOKE_RUN_TOKEN"

    let duration: TimeInterval
    let outputURL: URL
    let mode: CaptureMode
    let clockSource: AggregateClockSource
    let runToken: SmokeRecordRunToken

    init(
        duration: TimeInterval,
        outputURL: URL,
        mode: CaptureMode,
        clockSource: AggregateClockSource = .microphone,
        runToken: SmokeRecordRunToken
    ) {
        self.duration = duration
        self.outputURL = outputURL
        self.mode = mode
        self.clockSource = clockSource
        self.runToken = runToken
    }

    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SmokeRecordArguments? {
        guard let smokeIndex = arguments.firstIndex(of: "--smoke-record") else {
            return nil
        }

        let durationIndex = arguments.index(after: smokeIndex)
        guard durationIndex < arguments.endIndex else {
            throw SmokeRecordArgumentError.missingDuration
        }
        let durationValue = arguments[durationIndex]
        guard let duration = TimeInterval(durationValue), duration.isFinite, duration > 0 else {
            throw SmokeRecordArgumentError.invalidDuration(durationValue)
        }
        guard duration <= SmokeRecordArgumentError.maximumDuration else {
            throw SmokeRecordArgumentError.durationExceedsMaximum(
                durationValue,
                maximum: SmokeRecordArgumentError.maximumDuration
            )
        }

        let outputIndex = arguments.index(after: durationIndex)
        guard outputIndex < arguments.endIndex else {
            throw SmokeRecordArgumentError.missingOutput
        }
        let outputPath = arguments[outputIndex]
        guard !outputPath.isEmpty, outputPath != "--mode" else {
            throw SmokeRecordArgumentError.missingOutput
        }
        guard outputPath.hasPrefix("/") else {
            throw SmokeRecordArgumentError.outputPathMustBeAbsolute(outputPath)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        guard outputURL.path != "/" else {
            throw SmokeRecordArgumentError.outputPathMustNotBeRoot
        }
        guard !outputURL.hasDirectoryPath else {
            throw SmokeRecordArgumentError.outputPathMustBeFile(outputPath)
        }
        guard outputURL.standardizedFileURL.path == outputPath else {
            throw SmokeRecordArgumentError.outputPathMustBeStandardized(outputPath)
        }

        let modeFlagIndex = arguments.index(after: outputIndex)
        guard modeFlagIndex < arguments.endIndex else {
            throw SmokeRecordArgumentError.missingModeFlag
        }
        guard arguments[modeFlagIndex] == "--mode" else {
            throw SmokeRecordArgumentError.unexpectedArgument(arguments[modeFlagIndex])
        }

        let modeIndex = arguments.index(after: modeFlagIndex)
        guard modeIndex < arguments.endIndex else {
            throw SmokeRecordArgumentError.missingMode
        }
        let modeValue = arguments[modeIndex]
        guard let mode = CaptureMode(rawValue: modeValue) else {
            throw SmokeRecordArgumentError.unknownMode(modeValue)
        }
        guard mode == .micOnly || mode == .systemOnly || mode == .micAndSystem else {
            throw SmokeRecordArgumentError.unsupportedMode(mode)
        }

        var clockSource: AggregateClockSource = .microphone
        var trailingIndex = arguments.index(after: modeIndex)
        if trailingIndex < arguments.endIndex, arguments[trailingIndex] == "--clock" {
            let clockIndex = arguments.index(after: trailingIndex)
            guard clockIndex < arguments.endIndex else {
                throw SmokeRecordArgumentError.missingClockSource
            }
            switch arguments[clockIndex] {
            case "microphone":
                clockSource = .microphone
            case "output":
                clockSource = .output
            default:
                throw SmokeRecordArgumentError.unknownClockSource(arguments[clockIndex])
            }
            trailingIndex = arguments.index(after: clockIndex)
        }

        if trailingIndex < arguments.endIndex {
            throw SmokeRecordArgumentError.unexpectedArgument(arguments[trailingIndex])
        }
        guard let runTokenValue = environment[runTokenEnvironmentKey], !runTokenValue.isEmpty else {
            throw SmokeRecordArgumentError.missingRunToken
        }
        guard let runToken = SmokeRecordRunToken(rawValue: runTokenValue) else {
            throw SmokeRecordArgumentError.invalidRunToken(runTokenValue)
        }

        return SmokeRecordArguments(
            duration: duration,
            outputURL: outputURL,
            mode: mode,
            clockSource: clockSource,
            runToken: runToken
        )
    }
}

nonisolated struct SmokeRecordProbeSidecars: Equatable, Sendable {
    let runToken: SmokeRecordRunToken
    let requestURL: URL
    let mutedURL: URL
    let doneURL: URL
    let cancellationURL: URL
    let cancellationAcknowledgementURL: URL
    let successURL: URL

    init(outputURL: URL, runToken: SmokeRecordRunToken) {
        self.runToken = runToken
        let outputPath = outputURL.path
        requestURL = URL(fileURLWithPath: outputPath + ".probe-request")
        mutedURL = URL(fileURLWithPath: outputPath + ".probe-muted")
        doneURL = URL(fileURLWithPath: outputPath + ".probe-done")
        cancellationURL = URL(fileURLWithPath: outputPath + ".cancel-request")
        cancellationAcknowledgementURL = URL(fileURLWithPath: outputPath + ".cancel-ack")
        successURL = URL(fileURLWithPath: outputPath + ".smoke-success")
    }

    var probeURLs: [URL] {
        [
            requestURL,
            mutedURL,
            doneURL,
        ]
    }

    fileprivate var claimGuardURLs: [URL] {
        probeURLs + [successURL]
    }

    func temporaryURL(for targetURL: URL) -> URL {
        URL(fileURLWithPath: "\(targetURL.path).tmp.\(runToken.rawValue)")
    }
}

nonisolated enum SmokeRecordPathEntry {
    static func exists(at url: URL, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

nonisolated struct SmokeRecordSidecarStore: Equatable, Sendable {
    let sidecars: SmokeRecordProbeSidecars

    func claim(fileManager: FileManager = .default) throws {
        guard let staleURL = sidecars.claimGuardURLs.first(where: {
            SmokeRecordPathEntry.exists(at: $0, fileManager: fileManager)
        }) else {
            return
        }

        throw SmokeRecordRuntimeError.staleSidecar(staleURL.path)
    }

    func createRequest(fileManager: FileManager = .default) throws {
        try atomicallyCreate(
            sidecars.requestURL,
            temporaryURL: sidecars.temporaryURL(for: sidecars.requestURL),
            fileManager: fileManager
        )
    }

    func createDone(fileManager: FileManager = .default) throws {
        try atomicallyCreate(
            sidecars.doneURL,
            temporaryURL: sidecars.temporaryURL(for: sidecars.doneURL),
            fileManager: fileManager
        )
    }

    func createCancellationAcknowledgement(fileManager: FileManager = .default) throws {
        try atomicallyCreate(
            sidecars.cancellationAcknowledgementURL,
            temporaryURL: sidecars.temporaryURL(for: sidecars.cancellationAcknowledgementURL),
            fileManager: fileManager
        )
    }

    func createSuccess(fileManager: FileManager = .default) throws {
        try atomicallyCreate(
            sidecars.successURL,
            temporaryURL: sidecars.temporaryURL(for: sidecars.successURL),
            fileManager: fileManager
        )
    }

    func removeMatchingProbeMarkers(fileManager: FileManager = .default) throws {
        var firstError: Error?
        for url in sidecars.probeURLs where sidecars.runToken.matches(contentsOf: url, fileManager: fileManager) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func atomicallyCreate(
        _ targetURL: URL,
        temporaryURL: URL,
        fileManager: FileManager
    ) throws {
        if SmokeRecordPathEntry.exists(at: targetURL, fileManager: fileManager) {
            throw SmokeRecordRuntimeError.staleSidecar(targetURL.path)
        }
        if SmokeRecordPathEntry.exists(at: temporaryURL, fileManager: fileManager) {
            throw SmokeRecordRuntimeError.staleSidecar(temporaryURL.path)
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try sidecars.runToken.data.write(to: temporaryURL, options: .withoutOverwriting)
        } catch {
            if SmokeRecordPathEntry.exists(at: temporaryURL, fileManager: fileManager) {
                throw SmokeRecordRuntimeError.staleSidecar(temporaryURL.path)
            }
            throw error
        }
        do {
            try noClobberPublish(temporaryURL: temporaryURL, targetURL: targetURL)
        } catch {
            removeTemporaryIfOwned(temporaryURL, fileManager: fileManager)
            throw error
        }
        removeTemporaryIfOwned(temporaryURL, fileManager: fileManager)
    }

    private func removeTemporaryIfOwned(_ temporaryURL: URL, fileManager: FileManager) {
        guard sidecars.runToken.matches(contentsOf: temporaryURL, fileManager: fileManager) else {
            return
        }
        try? fileManager.removeItem(at: temporaryURL)
    }

    private func noClobberPublish(temporaryURL: URL, targetURL: URL) throws {
        let result = temporaryURL.path.withCString { temporaryPath in
            targetURL.path.withCString { targetPath in
                link(temporaryPath, targetPath)
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw SmokeRecordRuntimeError.staleSidecar(targetURL.path)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

nonisolated protocol SmokeRecordCaptureSessioning: Actor {
    func start(configuration: RecordingConfiguration) async throws -> CaptureStartResult
    func stop() async throws -> FinishedRecordingOutput
    func hasPendingCleanup() -> Bool
}

extension CaptureSession: SmokeRecordCaptureSessioning {}

nonisolated enum SmokeRecordStimulusDecision: Equatable, Sendable {
    case none
    case externalSpeechWithSelfExclusionProbe(SmokeRecordProbeSidecars)

    static func make(mode: CaptureMode, outputURL: URL, runToken: SmokeRecordRunToken) -> SmokeRecordStimulusDecision {
        switch mode {
        case .micOnly:
            return .none
        case .systemOnly:
            return .externalSpeechWithSelfExclusionProbe(SmokeRecordProbeSidecars(outputURL: outputURL, runToken: runToken))
        case .micAndSystem:
            return .externalSpeechWithSelfExclusionProbe(SmokeRecordProbeSidecars(outputURL: outputURL, runToken: runToken))
        }
    }
}

nonisolated enum SmokeRecordRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case probeIncompleteBeforeDuration
    case cancellationRequested
    case outputAlreadyExists(String)
    case staleSidecar(String)

    var description: String {
        switch self {
        case .probeIncompleteBeforeDuration:
            return "probe-incomplete-before-duration"
        case .cancellationRequested:
            return "smoke-cancellation-requested"
        case .outputAlreadyExists(let path):
            return "smoke output already exists: \(path)"
        case .staleSidecar(let path):
            return "smoke sidecar already exists: \(path)"
        }
    }
}

nonisolated enum SmokeRecordProbeCompletionEvent: Equatable, Sendable {
    case durationElapsed
    case probeCompleted
    case cancellationRequested
    case cancellationMonitorStopped
}

nonisolated enum SmokeRecordStartupEvent: Sendable {
    case started(CaptureStartResult)
    case cancellationRequested
    case cancellationMonitorStopped
}

extension SmokeRecordProbeCompletionEvent {
    var startupEvent: SmokeRecordStartupEvent {
        switch self {
        case .cancellationRequested:
            return .cancellationRequested
        case .cancellationMonitorStopped:
            return .cancellationMonitorStopped
        case .durationElapsed, .probeCompleted:
            return .cancellationMonitorStopped
        }
    }
}

nonisolated struct SmokeRecordProbeCompletionPolicy: Equatable, Sendable {
    private let requiresProbe: Bool
    private var probeCompleted = false

    init(requiresProbe: Bool = true) {
        self.requiresProbe = requiresProbe
    }

    mutating func record(_ event: SmokeRecordProbeCompletionEvent) throws -> Bool {
        switch event {
        case .probeCompleted:
            probeCompleted = true
            return false
        case .durationElapsed:
            guard !requiresProbe || probeCompleted else {
                throw SmokeRecordRuntimeError.probeIncompleteBeforeDuration
            }
            return true
        case .cancellationRequested:
            throw SmokeRecordRuntimeError.cancellationRequested
        case .cancellationMonitorStopped:
            return false
        }
    }
}

nonisolated struct SmokeRecordCancellationMonitor: Equatable, Sendable {
    let cancellationURL: URL
    let runToken: SmokeRecordRunToken
    let pollingInterval: Duration

    init(cancellationURL: URL, runToken: SmokeRecordRunToken, pollingInterval: Duration = .milliseconds(50)) {
        self.cancellationURL = cancellationURL
        self.runToken = runToken
        self.pollingInterval = pollingInterval
    }

    func wait() async -> SmokeRecordProbeCompletionEvent {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            if runToken.matches(contentsOf: cancellationURL) {
                return .cancellationRequested
            }
            do {
                try await clock.sleep(for: pollingInterval)
            } catch {
                return .cancellationMonitorStopped
            }
        }
        return .cancellationMonitorStopped
    }
}

nonisolated struct SmokeRecordCancellationAcknowledgementLifecycle: Equatable, Sendable {
    private var matchingCancellationObserved = false
    private var cleanupFinished = false

    init() {}

    mutating func recordMatchingCancellation() {
        matchingCancellationObserved = true
    }

    mutating func recordCleanupFinished() {
        cleanupFinished = true
    }

    var shouldPublishAcknowledgement: Bool {
        matchingCancellationObserved && cleanupFinished
    }
}

nonisolated struct SmokeRecordCaptureLifecycle: Equatable, Sendable {
    private(set) var shouldAttemptStop = false

    init() {}

    mutating func recordStartAttempted() {
        shouldAttemptStop = true
    }

    mutating func recordCleanupSettled() {
        shouldAttemptStop = false
    }
}

nonisolated struct SmokeRecordOutputProvenance: Equatable, Sendable {
    let outputURL: URL
    let existedAtEntry: Bool

    init(outputURL: URL, existedAtEntry: Bool) {
        self.outputURL = outputURL
        self.existedAtEntry = existedAtEntry
    }

    static func capture(outputURL: URL, fileManager: FileManager = .default) -> SmokeRecordOutputProvenance {
        SmokeRecordOutputProvenance(
            outputURL: outputURL,
            existedAtEntry: pathEntryExists(atPath: outputURL.path, fileManager: fileManager)
        )
    }

    func validateStart() throws {
        if existedAtEntry {
            throw SmokeRecordRuntimeError.outputAlreadyExists(outputURL.path)
        }
    }

    private static func pathEntryExists(atPath path: String, fileManager: FileManager) -> Bool {
        SmokeRecordPathEntry.exists(at: URL(fileURLWithPath: path), fileManager: fileManager)
    }
}

private enum SmokeRecordProbeError: Error, CustomStringConvertible {
    case missingMuteAcknowledgement(String)
    case soundUnavailable(String)
    case playbackFailed(String)
    case playbackTimedOut(String)

    var description: String {
        switch self {
        case .missingMuteAcknowledgement(let path):
            return "self-exclusion probe mute acknowledgement not received: \(path)"
        case .soundUnavailable(let path):
            return "self-exclusion probe sound unavailable: \(path)"
        case .playbackFailed(let path):
            return "self-exclusion probe sound failed to play: \(path)"
        case .playbackTimedOut(let path):
            return "self-exclusion probe sound playback timed out: \(path)"
        }
    }
}

nonisolated struct SmokeRecordProbePlaybackCompletion: Equatable, Sendable {
    let isStillPlayingAfterWait: Bool

    var logStatus: String {
        isStillPlayingAfterWait ? "playback-timeout" : "completed"
    }
}

@MainActor
private final class SmokeSelfExclusionProbe {
    private let sidecars: SmokeRecordProbeSidecars
    private let sidecarStore: SmokeRecordSidecarStore
    private let fileManager: FileManager
    private var sound: NSSound?
    private var requestPublished = false
    private var donePublished = false
    private var endLogged = false

    init(sidecars: SmokeRecordProbeSidecars, fileManager: FileManager = .default) {
        self.sidecars = sidecars
        sidecarStore = SmokeRecordSidecarStore(sidecars: sidecars)
        self.fileManager = fileManager
    }

    func run() async throws {
        defer {
            cleanupPublishedRequestIfNeeded()
        }

        try sidecarStore.createRequest(fileManager: fileManager)
        requestPublished = true
        NoteTakerLog.smoke.info("event=probe-request path=\(self.sidecars.requestURL.path, privacy: .public)")

        let acknowledged = try await waitForMatchingToken(at: sidecars.mutedURL, timeout: .seconds(2))
        guard acknowledged else {
            NoteTakerLog.smoke.error("event=probe-error reason=missing-muted-ack path=\(self.sidecars.mutedURL.path, privacy: .public)")
            throw SmokeRecordProbeError.missingMuteAcknowledgement(sidecars.mutedURL.path)
        }

        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard let probeSound = NSSound(contentsOf: soundURL, byReference: true) else {
            NoteTakerLog.smoke.error("event=probe-error reason=sound-unavailable path=\(soundURL.path, privacy: .public)")
            throw SmokeRecordProbeError.soundUnavailable(soundURL.path)
        }
        sound = probeSound

        NoteTakerLog.smoke.info("event=probe-start sound=\(soundURL.path, privacy: .public)")
        let didPlay = probeSound.play()
        NoteTakerLog.smoke.info("event=probe-play result=\(didPlay, privacy: .public)")
        guard didPlay else {
            NoteTakerLog.smoke.error("event=probe-error reason=play-failed path=\(soundURL.path, privacy: .public)")
            throw SmokeRecordProbeError.playbackFailed(soundURL.path)
        }

        let playbackCompletion = try await waitForPlaybackToEnd(probeSound, timeout: .seconds(3))
        probeSound.stop()
        sound = nil
        guard !playbackCompletion.isStillPlayingAfterWait else {
            NoteTakerLog.smoke.error("event=probe-error reason=playback-timeout path=\(soundURL.path, privacy: .public)")
            logProbeEnd(status: playbackCompletion.logStatus)
            throw SmokeRecordProbeError.playbackTimedOut(soundURL.path)
        }
        try signalDoneIfNeeded()
        logProbeEnd(status: playbackCompletion.logStatus)
    }

    private func waitForMatchingToken(at url: URL, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if sidecars.runToken.matches(contentsOf: url, fileManager: fileManager) {
                return true
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        return sidecars.runToken.matches(contentsOf: url, fileManager: fileManager)
    }

    private func waitForPlaybackToEnd(_ sound: NSSound, timeout: Duration) async throws -> SmokeRecordProbePlaybackCompletion {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sound.isPlaying, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(50))
        }
        return SmokeRecordProbePlaybackCompletion(isStillPlayingAfterWait: sound.isPlaying)
    }

    private func cleanupPublishedRequestIfNeeded() {
        sound?.stop()
        sound = nil
        guard requestPublished else {
            return
        }
        do {
            try signalDoneIfNeeded()
        } catch {
            NoteTakerLog.smoke.error("event=probe-cleanup-error error=\(String(describing: error), privacy: .public)")
        }
        if !endLogged {
            logProbeEnd(status: "cleanup")
        }
    }

    private func signalDoneIfNeeded() throws {
        if donePublished {
            return
        }
        try sidecarStore.createDone(fileManager: fileManager)
        donePublished = true
    }

    private func logProbeEnd(status: String) {
        endLogged = true
        NoteTakerLog.smoke.info("event=probe-end status=\(status, privacy: .public)")
    }
}

@MainActor
private func runSmokeSelfExclusionProbe(sidecars: SmokeRecordProbeSidecars) async throws {
    try await SmokeSelfExclusionProbe(sidecars: sidecars).run()
}

private nonisolated func startSmokeCaptureSession(
    _ session: any SmokeRecordCaptureSessioning,
    arguments: SmokeRecordArguments
) async throws -> SmokeRecordStartupEvent {
    try Task.checkCancellation()
    let result = try await session.start(configuration: RecordingConfiguration(
        mode: arguments.mode,
        microphoneUID: nil,
        outputURL: arguments.outputURL,
        microphoneGain: 1.0,
        systemGain: 1.0,
        clockSource: arguments.clockSource
    ))
    return .started(result)
}

@MainActor
final class SmokeRecordCommand {
    private let session: any SmokeRecordCaptureSessioning
    private let terminate: () -> Void

    init(
        session: any SmokeRecordCaptureSessioning = CaptureSession(),
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.session = session
        self.terminate = terminate
    }

    func run(_ arguments: SmokeRecordArguments) async {
        let outputProvenance = SmokeRecordOutputProvenance.capture(outputURL: arguments.outputURL)
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: arguments.runToken)
        let sidecarStore = SmokeRecordSidecarStore(
            sidecars: sidecars
        )
        var captureLifecycle = SmokeRecordCaptureLifecycle()
        var acknowledgementLifecycle = SmokeRecordCancellationAcknowledgementLifecycle()
        var sidecarsClaimed = false
        var completedSuccessfully = false

        do {
            try outputProvenance.validateStart()
            try sidecarStore.claim()
            sidecarsClaimed = true
            try FileManager.default.createDirectory(
                at: arguments.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            NoteTakerLog.smoke.info(
                "event=start mode=\(arguments.mode.rawValue, privacy: .public) output=\(arguments.outputURL.path, privacy: .public) duration=\(arguments.duration, privacy: .public)"
            )

            captureLifecycle.recordStartAttempted()
            let startResult = try await startCaptureSession(
                session,
                arguments: arguments,
                sidecars: sidecars
            )
            logWarnings(startResult.warnings, phase: "start")

            NoteTakerLog.smoke.info(
                "event=channel-map sampleRate=\(startResult.aggregateSampleRate, privacy: .public) mic=\(String(describing: startResult.channelMap.microphoneChannels), privacy: .public) system=\(String(describing: startResult.channelMap.systemChannels), privacy: .public) confidence=\(String(describing: startResult.channelMap.confidence), privacy: .public)"
            )

            try await waitForRecordingWindow(arguments, sidecars: sidecars)

            let output = try await session.stop()
            captureLifecycle.recordCleanupSettled()
            logFinishedOutput(output, event: "stop")
            completedSuccessfully = true
        } catch {
            if (error as? SmokeRecordRuntimeError) == .cancellationRequested {
                acknowledgementLifecycle.recordMatchingCancellation()
            }
            NoteTakerLog.smoke.error("event=error error=\(String(describing: error), privacy: .public)")
            if captureLifecycle.shouldAttemptStop {
                if await settleCaptureAfterError() {
                    captureLifecycle.recordCleanupSettled()
                }
            }
        }

        if !captureLifecycle.shouldAttemptStop,
           arguments.runToken.matches(contentsOf: sidecars.cancellationURL) {
            acknowledgementLifecycle.recordMatchingCancellation()
            completedSuccessfully = false
        }

        var sidecarCleanupSucceeded = true
        if sidecarsClaimed {
            do {
                try sidecarStore.removeMatchingProbeMarkers()
            } catch {
                sidecarCleanupSucceeded = false
                NoteTakerLog.smoke.error(
                    "event=sidecar-cleanup-error error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        if !captureLifecycle.shouldAttemptStop {
            acknowledgementLifecycle.recordCleanupFinished()
        }
        if acknowledgementLifecycle.shouldPublishAcknowledgement {
            do {
                try sidecarStore.createCancellationAcknowledgement()
            } catch {
                NoteTakerLog.smoke.error(
                    "event=cancel-ack-error error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        if completedSuccessfully, sidecarCleanupSucceeded {
            do {
                try sidecarStore.createSuccess()
            } catch {
                NoteTakerLog.smoke.error(
                    "event=success-marker-error error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        terminate()
    }

    private func settleCaptureAfterError() async -> Bool {
        if !(await session.hasPendingCleanup()) {
            return true
        }

        let clock = ContinuousClock()
        for attempt in 1...3 {
            do {
                let output = try await session.stop()
                logFinishedOutput(output, event: "stop-after-error")
                return true
            } catch {
                NoteTakerLog.smoke.error(
                    "event=cleanup-error attempt=\(attempt, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                if !(await session.hasPendingCleanup()) {
                    return true
                }
                if attempt < 3 {
                    try? await clock.sleep(for: .milliseconds(50))
                }
            }
        }
        return false
    }

    private func startCaptureSession(
        _ session: any SmokeRecordCaptureSessioning,
        arguments: SmokeRecordArguments,
        sidecars: SmokeRecordProbeSidecars
    ) async throws -> CaptureStartResult {
        try await withThrowingTaskGroup(of: SmokeRecordStartupEvent.self) { group in
            group.addTask { [arguments, session] in
                try await startSmokeCaptureSession(session, arguments: arguments)
            }
            let cancellationMonitor = SmokeRecordCancellationMonitor(
                cancellationURL: sidecars.cancellationURL,
                runToken: sidecars.runToken
            )
            group.addTask { [cancellationMonitor] in
                await cancellationMonitor.wait().startupEvent
            }

            while let event = try await group.next() {
                switch event {
                case .started(let result):
                    group.cancelAll()
                    try await group.waitForAll()
                    return result
                case .cancellationRequested:
                    group.cancelAll()
                    do {
                        try await group.waitForAll()
                    } catch {
                        // Preserve the matching cancellation that won the startup race.
                    }
                    throw SmokeRecordRuntimeError.cancellationRequested
                case .cancellationMonitorStopped:
                    continue
                }
            }
            throw SmokeRecordRuntimeError.cancellationRequested
        }
    }

    private func waitForRecordingWindow(_ arguments: SmokeRecordArguments, sidecars: SmokeRecordProbeSidecars) async throws {
        switch SmokeRecordStimulusDecision.make(mode: arguments.mode, outputURL: arguments.outputURL, runToken: arguments.runToken) {
        case .none:
            try await waitForRecordingDurationAndProbe(
                duration: arguments.duration,
                sidecars: sidecars,
                requiresProbe: false
            )
        case .externalSpeechWithSelfExclusionProbe(let sidecars):
            try await waitForRecordingDurationAndProbe(
                duration: arguments.duration,
                sidecars: sidecars,
                requiresProbe: true
            )
        }
    }

    private func waitForRecordingDurationAndProbe(
        duration: TimeInterval,
        sidecars: SmokeRecordProbeSidecars,
        requiresProbe: Bool
    ) async throws {
        try await withThrowingTaskGroup(of: SmokeRecordProbeCompletionEvent.self) { group in
            var completionPolicy = SmokeRecordProbeCompletionPolicy(requiresProbe: requiresProbe)
            group.addTask { [duration] in
                try await sleepForRecordingDuration(duration)
                return .durationElapsed
            }
            let cancellationMonitor = SmokeRecordCancellationMonitor(
                cancellationURL: sidecars.cancellationURL,
                runToken: sidecars.runToken
            )
            group.addTask { [cancellationMonitor] in
                await cancellationMonitor.wait()
            }
            if requiresProbe {
                group.addTask { [sidecars] in
                    try await runSmokeSelfExclusionProbe(sidecars: sidecars)
                    return .probeCompleted
                }
            }

            while let result = try await group.next() {
                do {
                    if try completionPolicy.record(result) {
                        group.cancelAll()
                        try await group.waitForAll()
                        return
                    }
                } catch {
                    group.cancelAll()
                    do {
                        try await group.waitForAll()
                    } catch {
                        // Preserve the policy failure that explains why this smoke cannot certify the probe.
                    }
                    throw error
                }
            }
        }
    }

    private func logFinishedOutput(_ output: FinishedRecordingOutput, event: String) {
        NoteTakerLog.smoke.info(
            "event=\(event, privacy: .public) output=\(output.url.path, privacy: .public) duration=\(output.duration, privacy: .public) sampleRate=\(output.sampleRate, privacy: .public) channels=\(output.channelCount, privacy: .public)"
        )
        NoteTakerLog.smoke.info(
            "event=stats inputFrames=\(output.stats.inputFramesRead, privacy: .public) outputFrames=\(output.stats.outputFramesWritten, privacy: .public) writes=\(output.stats.fileWriteCalls, privacy: .public) dropped=\(output.stats.ringDroppedFrames, privacy: .public) overflows=\(output.stats.ringOverflowCount, privacy: .public) micPeak=\(output.stats.microphonePeak, privacy: .public) systemPeak=\(output.stats.systemPeak, privacy: .public)"
        )
        logWarnings(output.warnings, phase: "final")
    }

    private func logWarnings(_ warnings: [AudioCaptureWarning], phase: String) {
        NoteTakerLog.smoke.info(
            "event=warnings phase=\(phase, privacy: .public) count=\(warnings.count, privacy: .public)"
        )
        for warning in warnings {
            NoteTakerLog.smoke.warning(
                "event=warning phase=\(phase, privacy: .public) warning=\(self.warningDescription(warning), privacy: .public)"
            )
        }
    }

    private func warningDescription(_ warning: AudioCaptureWarning) -> String {
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

private nonisolated func sleepForRecordingDuration(_ duration: TimeInterval) async throws {
    let milliseconds = Int64((duration * 1_000).rounded())
    try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
}

@MainActor
final class SmokeRecordBootstrap: ObservableObject {
    private let result: Result<SmokeRecordArguments?, Error>
    private var task: Task<Void, Never>?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        result = Result { try SmokeRecordArguments.parse(arguments) }
        if case .success(.none) = result {
            return
        }
        startOnce()
    }

    func startOnce() {
        guard task == nil else {
            return
        }
        task = Task { [result] in
            switch result {
            case .success(.some(let arguments)):
                await SmokeRecordCommand().run(arguments)
            case .success(.none):
                break
            case .failure(let error):
                NoteTakerLog.smoke.error("event=error error=\(String(describing: error), privacy: .public)")
                NSApp.terminate(nil)
            }
        }
    }
}
