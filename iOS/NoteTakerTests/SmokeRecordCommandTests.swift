import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

private enum SmokeRecordSessionTestError: Error {
    case startupFailed
    case stopFailed
}

private enum SmokeRecordSessionTestEvent: Equatable, Sendable {
    case startEntered
    case startupCancellationFinished
    case stopEntered
    case stopFinished
}

private actor SmokeRecordSessionTestDouble: SmokeRecordCaptureSessioning {
    enum StartBehavior: Equatable, Sendable {
        case waitForCancellation
        case fail
        case succeed
    }

    enum StopBehavior: Equatable, Sendable {
        case succeeds
        case failsButSettles
        case remainsPending
        case failsOnceThenSucceeds
    }

    private let startBehavior: StartBehavior
    private let suspendStop: Bool
    private let stopBehavior: StopBehavior
    private var recordedEvents: [SmokeRecordSessionTestEvent] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var outputURL: URL?
    private var stopAttempts = 0
    private var cleanupPending = false

    init(
        startBehavior: StartBehavior,
        suspendStop: Bool = false,
        stopBehavior: StopBehavior? = nil
    ) {
        self.startBehavior = startBehavior
        self.suspendStop = suspendStop
        self.stopBehavior = stopBehavior ?? (startBehavior == .succeed ? .succeeds : .failsButSettles)
    }

    func start(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        recordedEvents.append(.startEntered)
        outputURL = configuration.outputURL
        cleanupPending = startBehavior != .fail
        switch startBehavior {
        case .waitForCancellation:
            do {
                try await ContinuousClock().sleep(for: .seconds(30))
                throw SmokeRecordSessionTestError.startupFailed
            } catch is CancellationError {
                recordedEvents.append(.startupCancellationFinished)
                throw CancellationError()
            }
        case .fail:
            throw SmokeRecordSessionTestError.startupFailed
        case .succeed:
            return CaptureStartResult(
                aggregateSampleRate: 48_000,
                channelMap: InputChannelMap(
                    microphoneChannels: [0],
                    systemChannels: [],
                    bufferLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
                    confidence: .terminalType
                )
            )
        }
    }

    func stop() async throws -> FinishedRecordingOutput {
        recordedEvents.append(.stopEntered)
        stopAttempts += 1
        if suspendStop {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        recordedEvents.append(.stopFinished)
        switch stopBehavior {
        case .succeeds:
            cleanupPending = false
            return try finishedOutput()
        case .failsButSettles:
            cleanupPending = false
            throw SmokeRecordSessionTestError.stopFailed
        case .remainsPending:
            cleanupPending = true
            throw SmokeRecordSessionTestError.stopFailed
        case .failsOnceThenSucceeds:
            if stopAttempts == 1 {
                cleanupPending = true
                throw SmokeRecordSessionTestError.stopFailed
            }
            cleanupPending = false
            return try finishedOutput()
        }
    }

    func hasPendingCleanup() -> Bool {
        cleanupPending
    }

    func events() -> [SmokeRecordSessionTestEvent] {
        recordedEvents
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func finishedOutput() throws -> FinishedRecordingOutput {
        guard let outputURL else {
            throw SmokeRecordSessionTestError.startupFailed
        }
        return FinishedRecordingOutput(
            url: outputURL,
            duration: 0.001,
            sampleRate: 48_000,
            channelCount: 2,
            bars: [],
            stats: RecordingWriterStats(
                inputFramesRead: 48,
                outputFramesWritten: 48,
                fileWriteCalls: 1,
                barsEmitted: 0,
                ringDroppedFrames: 0,
                ringOverflowCount: 0,
                microphonePeak: 0.5,
                systemPeak: 0
            ),
            warnings: []
        )
    }
}

@MainActor
private final class SmokeRecordTerminationSpy {
    private(set) var callCount = 0
    private(set) var acknowledgementWasPresent = false
    private(set) var successWasPresent = false

    func terminate(sidecars: SmokeRecordProbeSidecars) {
        callCount += 1
        acknowledgementWasPresent = sidecars.runToken.matches(
            contentsOf: sidecars.cancellationAcknowledgementURL
        )
        successWasPresent = sidecars.runToken.matches(contentsOf: sidecars.successURL)
    }
}

@Suite("Smoke record launch argument parsing")
struct SmokeRecordCommandTests {
    private let smokeRunToken = SmokeRecordRunToken(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let otherRunToken = SmokeRecordRunToken(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    private var smokeEnvironment: [String: String] {
        [SmokeRecordArguments.runTokenEnvironmentKey: smokeRunToken.rawValue]
    }

    @Test("normal launch arguments do not enter smoke mode")
    func normalLaunchesReturnNil() throws {
        #expect(try SmokeRecordArguments.parse([]) == nil)
        #expect(try SmokeRecordArguments.parse(["-uiTesting"]) == nil)
        #expect(try SmokeRecordArguments.parse(["/Applications/NoteTaker.app/Contents/MacOS/NoteTaker", "-uiTesting"]) == nil)
        #expect(try SmokeRecordArguments.parse(["-uiTesting"], environment: [:]) == nil)
    }

    @Test("exact mic-only smoke command parses typed duration output and mode")
    func exactMicOnlyCommandParses() throws {
        let parsed = try #require(try SmokeRecordArguments.parse([
            "--smoke-record", "2.5", "/tmp/smoke-output.m4a", "--mode", "micOnly"
        ], environment: smokeEnvironment))

        #expect(parsed == SmokeRecordArguments(
            duration: 2.5,
            outputURL: URL(fileURLWithPath: "/tmp/smoke-output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        ))
    }

    @Test("realistic executable-prefixed system-only smoke command parses")
    func executablePrefixedSystemOnlySmokeCommandParses() throws {
        let parsed = try #require(try SmokeRecordArguments.parse([
            "/Applications/NoteTaker.app/Contents/MacOS/NoteTaker",
            "--smoke-record", "2.5", "/tmp/smoke-output.m4a", "--mode", "systemOnly"
        ], environment: smokeEnvironment))

        #expect(parsed == SmokeRecordArguments(
            duration: 2.5,
            outputURL: URL(fileURLWithPath: "/tmp/smoke-output.m4a"),
            mode: .systemOnly,
            runToken: smokeRunToken
        ))
    }

    @Test("smoke mode requires a valid injected run token")
    func smokeModeRequiresValidInjectedRunToken() throws {
        #expect(throws: SmokeRecordArgumentError.missingRunToken) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a", "--mode", "micOnly"], environment: [:])
        }
        #expect(throws: SmokeRecordArgumentError.invalidRunToken("not-a-uuid")) {
            try SmokeRecordArguments.parse([
                "--smoke-record", "1", "/tmp/out.m4a", "--mode", "micOnly",
            ], environment: [SmokeRecordArguments.runTokenEnvironmentKey: "not-a-uuid"])
        }
    }

    @Test("run token preserves the exact validated UTF-8 environment value")
    func runTokenPreservesExactEnvironmentValue() throws {
        let lowercaseValue = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let token = try #require(SmokeRecordRunToken(rawValue: lowercaseValue))

        #expect(token.rawValue == lowercaseValue)
        #expect(token.data == Data(lowercaseValue.utf8))
    }

    @Test("smoke duration accepts one hour maximum and rejects oversized values")
    func durationMaximumIsBounded() throws {
        let boundary = try #require(try SmokeRecordArguments.parse([
            "--smoke-record", "3600", "/tmp/out.m4a", "--mode", "micOnly"
        ], environment: smokeEnvironment))
        #expect(boundary.duration == 3600)
        #expect(boundary.runToken == smokeRunToken)

        #expect(throws: SmokeRecordArgumentError.durationExceedsMaximum("3600.001", maximum: 3600)) {
            try SmokeRecordArguments.parse(["--smoke-record", "3600.001", "/tmp/out.m4a", "--mode", "micOnly"], environment: smokeEnvironment)
        }
    }

    @Test("missing and malformed duration fail with typed errors")
    func durationErrorsAreTyped() throws {
        #expect(throws: SmokeRecordArgumentError.missingDuration) {
            try SmokeRecordArguments.parse(["--smoke-record"])
        }
        #expect(throws: SmokeRecordArgumentError.invalidDuration("NaN")) {
            try SmokeRecordArguments.parse(["--smoke-record", "NaN", "/tmp/out.m4a", "--mode", "micOnly"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.invalidDuration("0")) {
            try SmokeRecordArguments.parse(["--smoke-record", "0", "/tmp/out.m4a", "--mode", "micOnly"], environment: smokeEnvironment)
        }
    }

    @Test("missing output and mode fail with typed errors")
    func requiredArgumentErrorsAreTyped() throws {
        #expect(throws: SmokeRecordArgumentError.missingOutput) {
            try SmokeRecordArguments.parse(["--smoke-record", "1"])
        }
        #expect(throws: SmokeRecordArgumentError.missingModeFlag) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.missingMode) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a", "--mode"], environment: smokeEnvironment)
        }
    }

    @Test("output path must be absolute standardized non-root and file-shaped")
    func outputPathValidationIsStrict() throws {
        #expect(throws: SmokeRecordArgumentError.outputPathMustBeAbsolute("build/out.m4a")) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "build/out.m4a", "--mode", "micOnly"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.outputPathMustNotBeRoot) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/", "--mode", "micOnly"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.outputPathMustBeStandardized("/tmp/../tmp/out.m4a")) {
            try SmokeRecordArguments.parse([
                "--smoke-record", "1", "/tmp/../tmp/out.m4a", "--mode", "micOnly",
            ], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.outputPathMustBeFile("/tmp/.")) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/.", "--mode", "micOnly"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.outputPathMustBeFile("/tmp/out.m4a/")) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a/", "--mode", "micOnly"], environment: smokeEnvironment)
        }
    }

    @Test("unknown unsupported duplicate and trailing flags fail deterministically")
    func malformedSmokeCommandsFailDeterministically() throws {
        #expect(throws: SmokeRecordArgumentError.unknownMode("bogus")) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a", "--mode", "bogus"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.unsupportedMode(.micAndSystem)) {
            try SmokeRecordArguments.parse(["--smoke-record", "1", "/tmp/out.m4a", "--mode", "micAndSystem"], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.unexpectedArgument("--smoke-record")) {
            try SmokeRecordArguments.parse([
                "--smoke-record", "1", "/tmp/out.m4a", "--mode", "micOnly", "--smoke-record"
            ], environment: smokeEnvironment)
        }
        #expect(throws: SmokeRecordArgumentError.unexpectedArgument("--verbose")) {
            try SmokeRecordArguments.parse([
                "--smoke-record", "1", "/tmp/out.m4a", "--mode", "micOnly", "--verbose"
            ], environment: smokeEnvironment)
        }
    }

    @Test("smoke stimulus decision is pure and mode specific")
    func stimulusDecisionIsPureAndModeSpecific() throws {
        let output = URL(fileURLWithPath: "/tmp/smoke output.m4a")

        #expect(SmokeRecordStimulusDecision.make(mode: .micOnly, outputURL: output, runToken: smokeRunToken) == .none)

        #expect(SmokeRecordStimulusDecision.make(mode: .systemOnly, outputURL: output, runToken: smokeRunToken) == .externalSpeechWithSelfExclusionProbe(SmokeRecordProbeSidecars(outputURL: output, runToken: smokeRunToken)))
    }

    @Test("sidecar URLs append exact fixed suffixes to the complete output path")
    func probeSidecarURLsAppendExactSuffixes() {
        let sidecars = SmokeRecordProbeSidecars(outputURL: URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a"), runToken: smokeRunToken)

        #expect(sidecars.requestURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.probe-request"))
        #expect(sidecars.mutedURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.probe-muted"))
        #expect(sidecars.doneURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.probe-done"))
        #expect(sidecars.cancellationURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.cancel-request"))
        #expect(sidecars.cancellationAcknowledgementURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.cancel-ack"))
        #expect(sidecars.successURL == URL(fileURLWithPath: "/tmp/folder/name.with.dots.m4a.smoke-success"))
    }

    @Test("temporary sidecar path is deterministically token-qualified")
    func temporarySidecarPathIncludesToken() {
        let sidecars = SmokeRecordProbeSidecars(
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a"),
            runToken: smokeRunToken
        )

        #expect(
            sidecars.temporaryURL(for: sidecars.requestURL)
                == URL(fileURLWithPath: "/tmp/output.m4a.probe-request.tmp.\(smokeRunToken.rawValue)")
        )
    }

    @Test("probe completion policy rejects duration before probe completion")
    func probeCompletionPolicyRejectsDurationBeforeProbeCompletion() throws {
        var policy = SmokeRecordProbeCompletionPolicy()

        #expect(throws: SmokeRecordRuntimeError.probeIncompleteBeforeDuration) {
            try policy.record(.durationElapsed)
        }
    }

    @Test("probe completion policy accepts probe before duration")
    func probeCompletionPolicyAcceptsProbeBeforeDuration() throws {
        var policy = SmokeRecordProbeCompletionPolicy()

        #expect(try policy.record(.probeCompleted) == false)
        #expect(try policy.record(.durationElapsed))
    }

    @Test("recording completion policy propagates cancellation")
    func recordingCompletionPolicyPropagatesCancellation() throws {
        var systemPolicy = SmokeRecordProbeCompletionPolicy()
        var microphonePolicy = SmokeRecordProbeCompletionPolicy(requiresProbe: false)

        #expect(throws: SmokeRecordRuntimeError.cancellationRequested) {
            try systemPolicy.record(.cancellationRequested)
        }
        #expect(throws: SmokeRecordRuntimeError.cancellationRequested) {
            try microphonePolicy.record(.cancellationRequested)
        }
        #expect(try microphonePolicy.record(.durationElapsed))
    }

    @Test("cancellation monitor observes the exact sidecar and stops when its task is cancelled")
    func cancellationMonitorObservesSidecarAndTaskCancellation() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordCancellation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let cancellationURL = root.appendingPathComponent("output.m4a.cancel-request")
        let monitor = SmokeRecordCancellationMonitor(
            cancellationURL: cancellationURL,
            runToken: smokeRunToken,
            pollingInterval: .milliseconds(1)
        )
        try smokeRunToken.data.write(to: cancellationURL)
        #expect(await monitor.wait() == .cancellationRequested)

        try fileManager.removeItem(at: cancellationURL)
        let task = Task { await monitor.wait() }
        task.cancel()
        #expect(await task.value == .cancellationMonitorStopped)
    }

    @Test("cancellation monitor ignores mismatched request without deleting it")
    func cancellationMonitorIgnoresMismatchedRequestWithoutDeletingIt() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordMismatchedCancellation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let cancellationURL = root.appendingPathComponent("output.m4a.cancel-request")
        try otherRunToken.data.write(to: cancellationURL)
        let monitor = SmokeRecordCancellationMonitor(
            cancellationURL: cancellationURL,
            runToken: smokeRunToken,
            pollingInterval: .milliseconds(1)
        )

        let task = Task { await monitor.wait() }
        try await ContinuousClock().sleep(for: .milliseconds(20))
        task.cancel()

        #expect(await task.value == .cancellationMonitorStopped)
        #expect(try Data(contentsOf: cancellationURL) == otherRunToken.data)
    }

    @Test("sidecar ownership rejects stale acknowledgement without deleting unowned files")
    func sidecarOwnershipRejectsAndPreservesStaleAcknowledgement() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordSidecars-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(outputURL: root.appendingPathComponent("output.m4a"), runToken: smokeRunToken)
        let store = SmokeRecordSidecarStore(sidecars: sidecars)
        for url in sidecars.probeURLs {
            try smokeRunToken.data.write(to: url)
        }

        #expect(throws: SmokeRecordRuntimeError.staleSidecar(sidecars.requestURL.path)) {
            try store.claim(fileManager: fileManager)
        }
        for url in sidecars.probeURLs {
            #expect(SmokeRecordPathEntry.exists(at: url, fileManager: fileManager))
            #expect(try Data(contentsOf: url) == smokeRunToken.data)
        }
    }

    @Test("sidecar ownership rejects mismatched stale probe markers without deleting them")
    func sidecarOwnershipRejectsAndPreservesMismatchedProbeMarkers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordMismatchedSidecars-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(outputURL: root.appendingPathComponent("output.m4a"), runToken: smokeRunToken)
        let store = SmokeRecordSidecarStore(sidecars: sidecars)
        for url in sidecars.probeURLs {
            try otherRunToken.data.write(to: url)
        }

        #expect(throws: SmokeRecordRuntimeError.staleSidecar(sidecars.requestURL.path)) {
            try store.claim(fileManager: fileManager)
        }

        for url in sidecars.probeURLs {
            #expect(SmokeRecordPathEntry.exists(at: url, fileManager: fileManager))
            #expect(try Data(contentsOf: url) == otherRunToken.data)
        }
    }

    @Test("run token never treats a symbolic-link marker as owned")
    func runTokenDoesNotFollowSymbolicLinkMarkers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordSymlinkMarker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let target = root.appendingPathComponent("target")
        let marker = root.appendingPathComponent("output.m4a.cancel-request")
        try smokeRunToken.data.write(to: target)
        try fileManager.createSymbolicLink(at: marker, withDestinationURL: target)

        #expect(!smokeRunToken.matches(contentsOf: marker, fileManager: fileManager))
        #expect(try Data(contentsOf: target) == smokeRunToken.data)
    }

    @Test("sidecar cleanup removes matching probe markers but leaves Make-owned cancellation markers")
    func sidecarCleanupRemovesOnlyMatchingProbeMarkers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordMatchingSidecars-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(
            outputURL: root.appendingPathComponent("output.m4a"),
            runToken: smokeRunToken
        )
        let store = SmokeRecordSidecarStore(sidecars: sidecars)
        for url in sidecars.probeURLs + [sidecars.cancellationURL] {
            try smokeRunToken.data.write(to: url)
        }

        try store.removeMatchingProbeMarkers(fileManager: fileManager)

        for url in sidecars.probeURLs {
            #expect(!SmokeRecordPathEntry.exists(at: url, fileManager: fileManager))
        }
        #expect(try Data(contentsOf: sidecars.cancellationURL) == smokeRunToken.data)
    }

    @Test("an early cancellation request is valid while stale probe markers are not")
    func sidecarOwnershipAcceptsEarlyCancellation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordEarlyCancel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(outputURL: root.appendingPathComponent("output.m4a"), runToken: smokeRunToken)
        let store = SmokeRecordSidecarStore(sidecars: sidecars)
        try smokeRunToken.data.write(to: sidecars.cancellationURL)

        try store.claim(fileManager: fileManager)
        #expect(SmokeRecordPathEntry.exists(at: sidecars.cancellationURL, fileManager: fileManager))
        try store.removeMatchingProbeMarkers(fileManager: fileManager)
        #expect(SmokeRecordPathEntry.exists(at: sidecars.cancellationURL, fileManager: fileManager))
        #expect(try Data(contentsOf: sidecars.cancellationURL) == smokeRunToken.data)
    }

    @Test("atomic sidecar publication writes token and preserves an old fixed temp marker")
    func atomicSidecarPublicationCleansTemporaryMarker() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordAtomicSidecar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(outputURL: root.appendingPathComponent("output.m4a"), runToken: smokeRunToken)
        let store = SmokeRecordSidecarStore(sidecars: sidecars)
        let oldFixedTemporaryURL = URL(fileURLWithPath: sidecars.requestURL.path + ".tmp")
        try otherRunToken.data.write(to: oldFixedTemporaryURL)

        try store.createRequest(fileManager: fileManager)

        #expect(SmokeRecordPathEntry.exists(at: sidecars.requestURL, fileManager: fileManager))
        #expect(try Data(contentsOf: sidecars.requestURL) == smokeRunToken.data)
        #expect(try Data(contentsOf: oldFixedTemporaryURL) == otherRunToken.data)
        #expect(!SmokeRecordPathEntry.exists(at: sidecars.temporaryURL(for: sidecars.requestURL), fileManager: fileManager))
        #expect(throws: SmokeRecordRuntimeError.staleSidecar(sidecars.requestURL.path)) {
            try store.createRequest(fileManager: fileManager)
        }
    }

    @Test("cancel acknowledgement publication writes token and does not clobber existing acknowledgement")
    func cancelAcknowledgementPublicationWritesTokenWithoutClobbering() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordCancelAck-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let sidecars = SmokeRecordProbeSidecars(outputURL: root.appendingPathComponent("output.m4a"), runToken: smokeRunToken)
        let store = SmokeRecordSidecarStore(sidecars: sidecars)

        try store.createCancellationAcknowledgement(fileManager: fileManager)
        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
        #expect(throws: SmokeRecordRuntimeError.staleSidecar(sidecars.cancellationAcknowledgementURL.path)) {
            try store.createCancellationAcknowledgement(fileManager: fileManager)
        }
        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
    }

    @Test("successful command publishes an exact success token before termination")
    @MainActor
    func successfulCommandPublishesSuccessTokenBeforeTermination() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordSuccess-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 0.001,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(startBehavior: .succeed)
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )

        await command.run(arguments)

        #expect(try Data(contentsOf: sidecars.successURL) == smokeRunToken.data)
        #expect(terminationSpy.callCount == 1)
        #expect(terminationSpy.successWasPresent)
        #expect(!terminationSpy.acknowledgementWasPresent)
    }

    @Test("probe failure after capture start never publishes success")
    @MainActor
    func probeFailureAfterStartDoesNotPublishSuccess() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordProbeFailure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 0.001,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .systemOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(startBehavior: .succeed)
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )

        await command.run(arguments)

        #expect(await session.events() == [.startEntered, .stopEntered, .stopFinished])
        #expect(!SmokeRecordPathEntry.exists(at: sidecars.successURL, fileManager: fileManager))
        #expect(terminationSpy.callCount == 1)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("startup cancellation is awaited and cleanup finishes before acknowledgement and termination")
    @MainActor
    func startupCancellationAwaitsCleanupBeforeAcknowledgement() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordStartupCancellation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 30,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(
            startBehavior: .waitForCancellation,
            suspendStop: true
        )
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )
        let commandTask = Task { await command.run(arguments) }

        try await waitUntil { await session.events().contains(.startEntered) }
        try smokeRunToken.data.write(to: sidecars.cancellationURL)
        try await waitUntil { await session.events().contains(.stopEntered) }

        #expect(await session.events() == [
            .startEntered,
            .startupCancellationFinished,
            .stopEntered,
        ])
        #expect(!SmokeRecordPathEntry.exists(at: sidecars.cancellationAcknowledgementURL))

        await session.releaseStop()
        await commandTask.value

        #expect(await session.events() == [
            .startEntered,
            .startupCancellationFinished,
            .stopEntered,
            .stopFinished,
        ])
        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
        #expect(try Data(contentsOf: sidecars.cancellationURL) == smokeRunToken.data)
        #expect(terminationSpy.callCount == 1)
        #expect(terminationSpy.acknowledgementWasPresent)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("cancellation never acknowledges while capture cleanup remains pending")
    @MainActor
    func cancellationDoesNotAcknowledgePendingCleanup() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordPendingCleanup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 30,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(
            startBehavior: .waitForCancellation,
            stopBehavior: .remainsPending
        )
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )
        let commandTask = Task { await command.run(arguments) }

        try await waitUntil { await session.events().contains(.startEntered) }
        try smokeRunToken.data.write(to: sidecars.cancellationURL)
        await commandTask.value

        #expect(!SmokeRecordPathEntry.exists(at: sidecars.cancellationAcknowledgementURL))
        #expect(terminationSpy.callCount == 1)
        #expect(!terminationSpy.acknowledgementWasPresent)
    }

    @Test("cancellation retries pending cleanup before publishing acknowledgement")
    @MainActor
    func cancellationRetriesCleanupBeforeAcknowledgement() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordRetryCleanup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 30,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(
            startBehavior: .waitForCancellation,
            stopBehavior: .failsOnceThenSucceeds
        )
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )
        let commandTask = Task { await command.run(arguments) }

        try await waitUntil { await session.events().contains(.startEntered) }
        try smokeRunToken.data.write(to: sidecars.cancellationURL)
        await commandTask.value

        #expect(await session.events().filter { $0 == .stopEntered }.count == 2)
        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
        #expect(terminationSpy.acknowledgementWasPresent)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("cancellation arriving during successful stop is acknowledged instead of certified as success")
    @MainActor
    func cancellationDuringSuccessfulStopPublishesAcknowledgement() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordLateCancellation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 0.001,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(
            startBehavior: .succeed,
            suspendStop: true,
            stopBehavior: .succeeds
        )
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )
        let commandTask = Task { await command.run(arguments) }

        try await waitUntil { await session.events().contains(.stopEntered) }
        try smokeRunToken.data.write(to: sidecars.cancellationURL)
        await session.releaseStop()
        await commandTask.value

        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
        #expect(!SmokeRecordPathEntry.exists(at: sidecars.successURL, fileManager: fileManager))
        #expect(terminationSpy.acknowledgementWasPresent)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("cancellation during a throwing but settled stop still publishes acknowledgement")
    @MainActor
    func cancellationDuringSettledThrowingStopPublishesAcknowledgement() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordLateSettledFailure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 0.001,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        let session = SmokeRecordSessionTestDouble(
            startBehavior: .succeed,
            suspendStop: true,
            stopBehavior: .failsButSettles
        )
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )
        let commandTask = Task { await command.run(arguments) }

        try await waitUntil { await session.events().contains(.stopEntered) }
        try smokeRunToken.data.write(to: sidecars.cancellationURL)
        await session.releaseStop()
        await commandTask.value

        #expect(try Data(contentsOf: sidecars.cancellationAcknowledgementURL) == smokeRunToken.data)
        #expect(!SmokeRecordPathEntry.exists(at: sidecars.successURL, fileManager: fileManager))
        #expect(terminationSpy.acknowledgementWasPresent)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("unrelated startup failure and mismatched cancellation do not publish acknowledgement")
    @MainActor
    func unrelatedFailureDoesNotPublishCancellationAcknowledgement() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordUnrelatedFailure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let arguments = SmokeRecordArguments(
            duration: 1,
            outputURL: root.appendingPathComponent("output.m4a"),
            mode: .micOnly,
            runToken: smokeRunToken
        )
        let sidecars = SmokeRecordProbeSidecars(outputURL: arguments.outputURL, runToken: smokeRunToken)
        try otherRunToken.data.write(to: sidecars.cancellationURL)
        let session = SmokeRecordSessionTestDouble(startBehavior: .fail)
        let terminationSpy = SmokeRecordTerminationSpy()
        let command = SmokeRecordCommand(
            session: session,
            terminate: { terminationSpy.terminate(sidecars: sidecars) }
        )

        await command.run(arguments)

        #expect(!SmokeRecordPathEntry.exists(at: sidecars.cancellationAcknowledgementURL))
        #expect(try Data(contentsOf: sidecars.cancellationURL) == otherRunToken.data)
        #expect(terminationSpy.callCount == 1)
        #expect(!terminationSpy.acknowledgementWasPresent)
        #expect(!terminationSpy.successWasPresent)
    }

    @Test("capture cleanup remains required when start was attempted but did not return")
    func captureCleanupTracksStartAttemptRatherThanStartSuccess() {
        var lifecycle = SmokeRecordCaptureLifecycle()

        #expect(!lifecycle.shouldAttemptStop)
        lifecycle.recordStartAttempted()
        #expect(lifecycle.shouldAttemptStop)
        lifecycle.recordCleanupSettled()
        #expect(!lifecycle.shouldAttemptStop)
    }

    @Test("a pre-existing output is rejected")
    func preExistingOutputIsRejected() throws {
        let output = URL(fileURLWithPath: "/tmp/pre-existing-output.m4a")
        let provenance = SmokeRecordOutputProvenance(outputURL: output, existedAtEntry: true)

        #expect(throws: SmokeRecordRuntimeError.outputAlreadyExists(output.path)) {
            try provenance.validateStart()
        }
    }

    @Test("an absent output is accepted")
    func absentOutputIsAccepted() throws {
        let provenance = SmokeRecordOutputProvenance(
            outputURL: URL(fileURLWithPath: "/tmp/attempt-output.m4a"),
            existedAtEntry: false
        )

        try provenance.validateStart()
    }

    @Test("output provenance detects files directories and symlinks including dangling ones")
    func outputProvenanceDetectsEveryExistingEntryKind() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SmokeRecordOutputProvenance-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let file = root.appendingPathComponent("existing.m4a")
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        let symlink = root.appendingPathComponent("linked.m4a")
        let danglingSymlink = root.appendingPathComponent("dangling.m4a")
        try Data([0x01]).write(to: file)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: file)
        try fileManager.createSymbolicLink(
            atPath: danglingSymlink.path,
            withDestinationPath: root.appendingPathComponent("missing.m4a").path
        )

        for output in [file, directory, symlink, danglingSymlink] {
            let provenance = SmokeRecordOutputProvenance.capture(outputURL: output, fileManager: fileManager)
            #expect(provenance.existedAtEntry)
            #expect(throws: SmokeRecordRuntimeError.outputAlreadyExists(output.path)) {
                try provenance.validateStart()
            }
        }

        let absent = root.appendingPathComponent("absent.m4a")
        let absentProvenance = SmokeRecordOutputProvenance.capture(outputURL: absent, fileManager: fileManager)
        #expect(!absentProvenance.existedAtEntry)
        try absentProvenance.validateStart()
    }

    @Test("cancellation acknowledgement is gated until matching cancellation and cleanup finish")
    func cancellationAcknowledgementLifecycleRequiresMatchingCancellationAndCleanup() {
        var lifecycle = SmokeRecordCancellationAcknowledgementLifecycle()

        #expect(!lifecycle.shouldPublishAcknowledgement)
        lifecycle.recordMatchingCancellation()
        #expect(!lifecycle.shouldPublishAcknowledgement)
        lifecycle.recordCleanupFinished()
        #expect(lifecycle.shouldPublishAcknowledgement)
    }

    @Test("playback timeout is a distinct probe completion status")
    func playbackTimeoutIsDistinctProbeCompletionStatus() {
        #expect(SmokeRecordProbePlaybackCompletion(isStillPlayingAfterWait: false).logStatus == "completed")
        #expect(SmokeRecordProbePlaybackCompletion(isStillPlayingAfterWait: true).logStatus == "playback-timeout")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                throw CancellationError()
            }
            try await clock.sleep(for: .milliseconds(1))
        }
    }

}
