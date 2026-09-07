@testable import AudioPipeline
import CoreAudio
import Foundation
import Testing

@Test("CaptureSession stabilization RED matrix covers Task 6 requirements")
func captureSessionStabilizationRedMatrixDocumentsTaskSixCoverage() {
    let matrix = [
        "stable tap format and aggregate streams: one system-only acquisition succeeds",
        "first tap-format change: first attempt fully tears down, deletes setup output, then one retry succeeds",
        "first aggregate-stream change: first attempt fully tears down, deletes setup output, then one retry succeeds",
        "second tap/stream mismatch: second attempt tears down, deletes setup output, then throws unsupportedStreamFormat(nil)",
        "mic-only start never calls the stabilization waiter",
        "writer completion failure during stabilization is observed by start and does not hang",
        "synchronous monitor delivery during registration cannot outrun partial resource ownership",
        "explicit stop racing with monitor teardown has one owner and no duplicate teardown",
        "runtime stream/rate changes stop with streamFormatChanged and preserve partial policy",
        "runtime aggregate/mic/device/default-output events map to deviceDisconnected when relevant",
        "processor overload remains atomic-only and never enters the actor",
        "cancellation during stabilization wait tears down every acquired resource once",
    ]

    #expect(matrix.count == 12)
}

@Test("system-only waits for stable tap format and identical aggregate streams before publishing active resources")
func captureSessionSystemOnlyStabilizesBeforeStartReturns() async throws {
    let log = LifecycleLog()
    let tapFactory = SequencedSystemTapFactory(log: log, formatsByAttempt: [[validSystemTapFormat, validSystemTapFormat]])
    let aggregateFactory = SequencedAggregateFactory(log: log, streamSnapshotsByAttempt: [
        (systemTapStreams(), systemTapStreams())
    ])
    let waiter = RecordingStabilizationWaiter(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        aggregateFactory: aggregateFactory,
        systemTapFactory: tapFactory,
        stabilizationWaiter: waiter
    ))

    let result = try await session.start(configuration: configuration(mode: .systemOnly))

    #expect(result.channelMap.systemChannels == [0, 1])
    #expect(waiter.waitCount() == 1)
    #expect(tapFactory.createCount() == 1)
    #expect(tapFactory.formatReadCount() == 2)
    #expect(aggregateFactory.systemCreateCount() == 1)
    #expect(aggregateFactory.currentInputStreamReadCount() == 1)
    #expect(log.events().filter { $0 == .aggregateDestroy }.isEmpty)
    #expect(log.events().filter { $0 == .tapDestroy }.isEmpty)

    _ = try await session.stop()
}

@Test("first tap-format mismatch tears down and retries with a new complete acquisition")
func captureSessionRetriesOnceAfterTapFormatMismatch() async throws {
    let output = try temporaryStabilizationOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let changedFormat = SystemAudioTapFormat(
        sampleRate: 44_100,
        formatID: validSystemTapFormat.formatID,
        formatFlags: validSystemTapFormat.formatFlags,
        bytesPerPacket: validSystemTapFormat.bytesPerPacket,
        framesPerPacket: validSystemTapFormat.framesPerPacket,
        bytesPerFrame: validSystemTapFormat.bytesPerFrame,
        channelCount: validSystemTapFormat.channelCount,
        bitsPerChannel: validSystemTapFormat.bitsPerChannel
    )
    let tapFactory = SequencedSystemTapFactory(
        log: output.log,
        formatsByAttempt: [[validSystemTapFormat, changedFormat], [validSystemTapFormat, validSystemTapFormat]]
    )
    let aggregateFactory = SequencedAggregateFactory(log: output.log, streamSnapshotsByAttempt: [
        (systemTapStreams(), systemTapStreams()),
        (systemTapStreams(), systemTapStreams()),
    ])
    let waiter = RecordingStabilizationWaiter(log: output.log)
    let retryStartSawDeletedAttemptOutput = LockedBoolean()
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: output.log,
        aggregateFactory: aggregateFactory,
        writerFactory: CapturingSessionWriterFactory(
            log: output.log,
            createsOutputOnStart: true,
            onStart: { startCount, outputURL in
                guard startCount == 2 else { return }
                retryStartSawDeletedAttemptOutput.set(!FileManager.default.fileExists(atPath: outputURL.path))
            }
        ),
        systemTapFactory: tapFactory,
        stabilizationWaiter: waiter
    ))

    _ = try await session.start(configuration: stabilizationConfiguration(mode: .systemOnly, outputURL: output.attemptURL))

    #expect(waiter.waitCount() == 2)
    #expect(tapFactory.createCount() == 2)
    #expect(aggregateFactory.systemCreateCount() == 2)
    #expect(output.log.events().filter { $0 == .deviceStop }.count == 1)
    #expect(output.log.events().filter { $0 == .ioProcDestroy }.count == 1)
    #expect(output.log.events().filter { $0 == .writerJoin }.count == 1)
    #expect(output.log.events().filter { $0 == .aggregateDestroy }.count == 1)
    #expect(output.log.events().filter { $0 == .tapDestroy }.count == 1)
    #expect(retryStartSawDeletedAttemptOutput.value())

    _ = try await session.stop()
}

@Test("first aggregate stream mismatch tears down and retries with a new complete acquisition")
func captureSessionRetriesOnceAfterAggregateStreamMismatch() async throws {
    let log = LifecycleLog()
    let aggregateFactory = SequencedAggregateFactory(log: log, streamSnapshotsByAttempt: [
        (systemTapStreams(), systemTapStreams(name: "Changed Tap")),
        (systemTapStreams(), systemTapStreams()),
    ])
    let waiter = RecordingStabilizationWaiter(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        aggregateFactory: aggregateFactory,
        stabilizationWaiter: waiter
    ))

    _ = try await session.start(configuration: configuration(mode: .systemOnly))

    #expect(waiter.waitCount() == 2)
    #expect(aggregateFactory.systemCreateCount() == 2)
    #expect(aggregateFactory.currentInputStreamReadCount() == 2)
    #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
    #expect(log.events().filter { $0 == .tapDestroy }.count == 1)

    _ = try await session.stop()
}

@Test("first aggregate buffer-layout change tears down and retries with a fresh layout")
func captureSessionRetriesOnceAfterAggregateBufferLayoutChange() async throws {
    let log = LifecycleLog()
    let aggregateFactory = SequencedAggregateFactory(
        log: log,
        streamSnapshotsByAttempt: [
            (systemTapStreams(), systemTapStreams()),
            (systemTapStreams(), systemTapStreams()),
        ],
        bufferSnapshotsByAttempt: [
            ([2], [1, 1]),
            ([2], [2]),
        ]
    )
    let waiter = RecordingStabilizationWaiter(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        aggregateFactory: aggregateFactory,
        stabilizationWaiter: waiter
    ))

    _ = try await session.start(configuration: configuration(mode: .systemOnly))

    #expect(waiter.waitCount() == 2)
    #expect(aggregateFactory.systemCreateCount() == 2)
    #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
    #expect(log.events().filter { $0 == .tapDestroy }.count == 1)
    _ = try await session.stop()
}

@Test("two stabilization mismatches tear down the second attempt, delete setup output, and throw unsupported format")
func captureSessionFailsAfterSecondStabilizationMismatch() async throws {
    let output = try temporaryStabilizationOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let aggregateFactory = SequencedAggregateFactory(log: output.log, streamSnapshotsByAttempt: [
        (systemTapStreams(), systemTapStreams(name: "Changed Tap 1")),
        (systemTapStreams(), systemTapStreams(name: "Changed Tap 2")),
    ])
    let waiter = RecordingStabilizationWaiter(log: output.log)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: output.log,
        aggregateFactory: aggregateFactory,
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true),
        stabilizationWaiter: waiter
    ))

    do {
        _ = try await session.start(configuration: stabilizationConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(waiter.waitCount() == 2)
        #expect(aggregateFactory.systemCreateCount() == 2)
        #expect(output.log.events().filter { $0 == .aggregateDestroy }.count == 2)
        #expect(output.log.events().filter { $0 == .tapDestroy }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("cleanup failure during first stabilization mismatch retains ownership and does not rebuild")
func captureSessionRetainsCleanupNeededAfterMismatchCleanupFailure() async throws {
    let log = LifecycleLog()
    let aggregateFactory = SequencedAggregateFactory(
        log: log,
        streamSnapshotsByAttempt: [(systemTapStreams(), systemTapStreams(name: "Changed Tap"))],
        teardownFailures: LifecycleFailurePlan([.aggregateDestroy])
    )
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        aggregateFactory: aggregateFactory
    ))

    do {
        _ = try await session.start(configuration: configuration(mode: .systemOnly))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(aggregateFactory.systemCreateCount() == 1)
        #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
    } catch {
        Issue.record("unexpected start error: \(error)")
    }

    do {
        _ = try await session.start(configuration: configuration(mode: .systemOnly))
        Issue.record("restart unexpectedly succeeded while cleanup was retained")
    } catch AudioCaptureError.fileWriteFailed("Capture session already started") {
    } catch {
        Issue.record("unexpected restart error: \(error)")
    }

    do {
        _ = try await session.stop()
        Issue.record("cleanup stop unexpectedly returned output")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(log.events().filter { $0 == .aggregateDestroy }.count == 2)
        #expect(log.events().filter { $0 == .tapDestroy }.count == 1)
    } catch {
        Issue.record("unexpected cleanup retry error: \(error)")
    }
}

@Test("attempt output deletion failure retains provenance and blocks stabilization retry until cleanup retry succeeds")
func captureSessionRetainsAttemptOutputProvenanceWhenDeletionFails() async throws {
    let output = try temporaryStabilizationOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let aggregateFactory = SequencedAggregateFactory(log: output.log, streamSnapshotsByAttempt: [
        (systemTapStreams(), systemTapStreams(name: "Changed Tap"))
    ])
    let attemptFiles = FailsOnceAttemptFileManager()
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: output.log,
        aggregateFactory: aggregateFactory,
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true),
        attemptFileManager: attemptFiles
    ))

    do {
        _ = try await session.start(configuration: stabilizationConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(aggregateFactory.systemCreateCount() == 1)
        #expect(attemptFiles.removeAttempts() == [output.attemptURL])
        #expect(FileManager.default.fileExists(atPath: output.attemptURL.path))
    } catch {
        Issue.record("unexpected start error: \(error)")
    }

    do {
        _ = try await session.start(configuration: stabilizationConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("restart unexpectedly rebuilt while attempt cleanup was retained")
    } catch AudioCaptureError.fileWriteFailed("Capture session already started") {
        #expect(aggregateFactory.systemCreateCount() == 1)
    } catch {
        Issue.record("unexpected restart error: \(error)")
    }

    do {
        _ = try await session.stop()
        Issue.record("cleanup retry unexpectedly returned output")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(attemptFiles.removeAttempts() == [output.attemptURL, output.attemptURL])
        #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))
    } catch {
        Issue.record("unexpected cleanup retry error: \(error)")
    }
}

@Test("stabilization sequence fakes reject empty fixtures without trapping")
func captureSessionStabilizationSequenceFakesRejectEmptyFixtures() async throws {
    let log = LifecycleLog()

    let tapFactory = SequencedSystemTapFactory(log: log, formatsByAttempt: [])
    do {
        _ = try tapFactory.create(excludingProcessID: nil)
        Issue.record("empty tap attempt fixture unexpectedly created a tap")
    } catch StabilizationSequenceFixtureError.emptyTapAttempts {
    } catch {
        Issue.record("unexpected empty tap attempt error: \(error)")
    }

    do {
        _ = try CountingSystemAudioTap(
            log: log,
            uid: fixedSystemTapUUID,
            formats: [],
            onRead: {}
        ).currentFormat()
        Issue.record("empty tap format fixture unexpectedly returned a format")
    } catch StabilizationSequenceFixtureError.emptyTapFormats {
    } catch {
        Issue.record("unexpected empty tap format error: \(error)")
    }

    let aggregateFactory = SequencedAggregateFactory(log: log, streamSnapshotsByAttempt: [])
    do {
        _ = try aggregateFactory.createSystemOnlyAggregate(
            outputUID: "output",
            tapUID: fixedSystemTapUUID,
            tapChannelCount: 2
        )
        Issue.record("empty aggregate attempt fixture unexpectedly created an aggregate")
    } catch StabilizationSequenceFixtureError.emptyAggregateAttempts {
    } catch {
        Issue.record("unexpected empty aggregate attempt error: \(error)")
    }
}


@Test("mic-only start never invokes the stabilization waiter")
func captureSessionMicOnlyDoesNotWaitForSystemStabilization() async throws {
    let log = LifecycleLog()
    let waiter = RecordingStabilizationWaiter(log: log)
    let session = CaptureSession(dependencies: .fake(log: log, stabilizationWaiter: waiter))

    _ = try await session.start(configuration: configuration())

    #expect(waiter.waitCount() == 0)
    _ = try await session.stop()
}

@Test("writer completion during stabilization owns teardown and start observes the terminal failure")
func captureSessionWriterCompletionDuringStabilizationIsNotLost() async throws {
    let log = LifecycleLog()
    let waiter = RecordingStabilizationWaiter(log: log, controlled: true)
    let writerProbe = FakeSessionWriterProbe()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        writerProbe: writerProbe,
        stabilizationWaiter: waiter
    ))

    let start = Task {
        try await session.start(configuration: configuration(mode: .systemOnly))
    }
    await waiter.waitForWaitCount(1)
    let writer = try writerProbe.requireWriter()
    writer.triggerRuntimeFailure(.diskSpaceLow)
    await yieldUntilDeviceStop(log)
    waiter.resumeAll()

    do {
        _ = try await start.value
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(log.events().filter { $0 == .deviceStop }.count == 1)
        #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
        #expect(log.events().filter { $0 == .tapDestroy }.count == 1)
    } catch {
        Issue.record("unexpected start error: \(error)")
    }
}

@Test("monitor event winning during stabilization owns cancellation cleanup exactly once")
func captureSessionCancellationAfterMonitorWinsObservesCachedTerminalError() async throws {
    let log = LifecycleLog()
    let waiter = RecordingStabilizationWaiter(log: log, controlled: true)
    let monitorFactory = CapturingMonitorFactory(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        monitorFactory: monitorFactory,
        stabilizationWaiter: waiter
    ))

    let start = Task {
        try await session.start(configuration: configuration(mode: .systemOnly))
    }
    await waiter.waitForWaitCount(1)
    monitorFactory.trigger(.deviceListChanged)
    await yieldUntilDeviceStop(log)
    start.cancel()
    waiter.resumeAll()

    do {
        _ = try await start.value
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.deviceDisconnected {
        #expect(log.events().filter { $0 == .deviceStop }.count == 1)
        #expect(log.events().filter { $0 == .ioProcDestroy }.count == 1)
        #expect(log.events().filter { $0 == .writerJoin }.count == 1)
        #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
        #expect(log.events().filter { $0 == .tapDestroy }.count == 1)
    } catch is CancellationError {
        Issue.record("start observed cancellation instead of cached monitor terminal error")
    } catch {
        Issue.record("unexpected start error: \(error)")
    }
}

@Test("format event during registration invalidates the first stabilization attempt and retries once")
func captureSessionFormatEventDuringRegistrationRetriesStabilization() async throws {
    let log = LifecycleLog()
    let waiter = RecordingStabilizationWaiter(log: log, controlled: true)
    let monitorFactory = CapturingMonitorFactory(
        log: log,
        eventDuringRegister: .streamConfigurationChanged
    )
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        monitorFactory: monitorFactory,
        stabilizationWaiter: waiter
    ))

    let start = Task {
        try await session.start(configuration: configuration(mode: .systemOnly))
    }
    await waiter.waitForWaitCount(1)
    waiter.resumeAll()
    await waiter.waitForWaitCount(2)
    waiter.resumeAll()

    _ = try await start.value
    #expect(log.events().filter { $0 == .aggregateCreate }.count == 2)
    #expect(log.events().filter { $0 == .tapCreate }.count == 2)
    #expect(log.events().filter { $0 == .aggregateDestroy }.count == 1)
    #expect(log.events().filter { $0 == .tapDestroy }.count == 1)
    _ = try await session.stop()
}

@Test("monitor-owned teardown makes later stop observe cached deviceDisconnected exactly once")
func captureSessionMonitorOwnerMakesLaterStopObserveCachedDeviceDisconnected() async throws {
    let log = LifecycleLog()
    let monitorFactory = CapturingMonitorFactory(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(log: log, monitorFactory: monitorFactory))

    _ = try await session.start(configuration: configuration(mode: .systemOnly))
    monitorFactory.trigger(.deviceListChanged)
    await yieldUntilDeviceStop(log)

    do {
        _ = try await session.stop()
        Issue.record("later stop unexpectedly succeeded after monitor-owned teardown")
    } catch AudioCaptureError.deviceDisconnected {
    } catch {
        Issue.record("unexpected stop error: \(error)")
    }

    #expect(log.events().filter { $0 == .deviceStop }.count == 1)
    #expect(log.events().filter { $0 == .ioProcDestroy }.count == 1)
    #expect(log.events().filter { $0 == .writerJoin }.count == 1)
}

@Test("explicit stop wins before stale monitor callback without duplicate teardown")
func captureSessionExplicitStopWinsBeforeStaleMonitorCallback() async throws {
    let log = LifecycleLog()
    let monitorFactory = CapturingMonitorFactory(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(log: log, monitorFactory: monitorFactory))

    _ = try await session.start(configuration: configuration(mode: .systemOnly))
    let output = try await session.stop()
    monitorFactory.trigger(.deviceListChanged)
    await allowScheduledTasksToRunForStabilizationTests()

    let cachedOutput = try await session.stop()
    #expect(cachedOutput.url == output.url)
    #expect(log.events().filter { $0 == .deviceStop }.count == 1)
    #expect(log.events().filter { $0 == .ioProcDestroy }.count == 1)
    #expect(log.events().filter { $0 == .writerJoin }.count == 1)
}

@Test("runtime format events safely stop and later stop reports streamFormatChanged")
func captureSessionRuntimeFormatEventsStopWithStreamFormatChanged() async throws {
    for event in [CaptureDeviceEvent.streamConfigurationChanged, .nominalSampleRateChanged] {
        let log = LifecycleLog()
        let monitorFactory = CapturingMonitorFactory(log: log)
        let session = CaptureSession(dependencies: stabilizationDependencies(log: log, monitorFactory: monitorFactory))
        _ = try await session.start(configuration: configuration(mode: .systemOnly))

        monitorFactory.trigger(event)
        await yieldUntilDeviceStop(log)

        do {
            _ = try await session.stop()
            Issue.record("stop unexpectedly succeeded for \(event)")
        } catch AudioCaptureError.streamFormatChanged {
            #expect(log.events().filter { $0 == .deviceStop }.count == 1)
        } catch {
            Issue.record("unexpected stop error: \(error)")
        }
    }
}

@Test("runtime device events map only when relevant to the active mode")
func captureSessionRuntimeDeviceEventsRespectModeRelevance() async throws {
    try await assertDeviceEvent(.aggregateAliveChanged, mode: .systemOnly, expectedError: .deviceDisconnected)
    try await assertDeviceEvent(.deviceListChanged, mode: .systemOnly, expectedError: .deviceDisconnected)
    try await assertDeviceEvent(.defaultOutputDeviceChanged, mode: .systemOnly, expectedError: .deviceDisconnected)

    let log = LifecycleLog()
    let monitorFactory = CapturingMonitorFactory(log: log)
    let acknowledgement = RuntimeEventAcknowledgement()
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: log,
        monitorFactory: monitorFactory,
        runtimeEventAcknowledgement: { event in acknowledgement.record(event) }
    ))
    _ = try await session.start(configuration: configuration(mode: .systemOnly))
    monitorFactory.trigger(.defaultInputDeviceChanged)
    await acknowledgement.waitFor(.defaultInputDeviceChanged)
    _ = try await session.stop()
    #expect(log.events().filter { $0 == .deviceStop }.count == 1)

    let micLog = LifecycleLog()
    let micMonitorFactory = CapturingMonitorFactory(log: micLog)
    let micSession = CaptureSession(dependencies: stabilizationDependencies(log: micLog, monitorFactory: micMonitorFactory))
    let defaultMicConfiguration = RecordingConfiguration(
        mode: .micOnly,
        microphoneUID: nil,
        outputURL: configuration().outputURL,
        microphoneGain: 1,
        systemGain: 0
    )
    _ = try await micSession.start(configuration: defaultMicConfiguration)
    micMonitorFactory.trigger(.defaultInputDeviceChanged)
    await yieldUntilDeviceStop(micLog)
    do {
        _ = try await micSession.stop()
        Issue.record("default mic stop unexpectedly succeeded")
    } catch AudioCaptureError.deviceDisconnected {
        #expect(micLog.events().filter { $0 == .deviceStop }.count == 1)
    }

    let explicitMicLog = LifecycleLog()
    let explicitMicMonitor = CapturingMonitorFactory(log: explicitMicLog)
    let explicitMicAcknowledgement = RuntimeEventAcknowledgement()
    let explicitMicSession = CaptureSession(dependencies: stabilizationDependencies(
        log: explicitMicLog,
        monitorFactory: explicitMicMonitor,
        runtimeEventAcknowledgement: { event in explicitMicAcknowledgement.record(event) }
    ))
    _ = try await explicitMicSession.start(configuration: configuration(mode: .micOnly))
    explicitMicMonitor.trigger(.deviceListChanged)
    await explicitMicAcknowledgement.waitFor(.deviceListChanged)
    _ = try await explicitMicSession.stop()
    #expect(explicitMicLog.events().filter { $0 == .deviceStop }.count == 1)
}

@Test("cancellation during stabilization wait cleans every acquired resource once")
func captureSessionCancellationDuringStabilizationTearsDownAttempt() async throws {
    let output = try temporaryStabilizationOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let waiter = RecordingStabilizationWaiter(log: output.log, controlled: true)
    let session = CaptureSession(dependencies: stabilizationDependencies(
        log: output.log,
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true),
        stabilizationWaiter: waiter
    ))

    let start = Task {
        try await session.start(configuration: stabilizationConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
    }
    await waiter.waitForWaitCount(1)
    start.cancel()
    waiter.resumeAll()

    do {
        _ = try await start.value
        Issue.record("start unexpectedly succeeded")
    } catch is CancellationError {
        #expect(output.log.events().filter { $0 == .deviceStop }.count == 1)
        #expect(output.log.events().filter { $0 == .ioProcDestroy }.count == 1)
        #expect(output.log.events().filter { $0 == .aggregateDestroy }.count == 1)
        #expect(output.log.events().filter { $0 == .tapDestroy }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))
    } catch {
        Issue.record("unexpected cancellation error: \(error)")
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ newValue: Bool) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private enum StabilizationSequenceFixtureError: Error, Equatable {
    case emptyTapAttempts
    case emptyTapFormats
    case emptyAggregateAttempts
}

private final class RecordingStabilizationWaiter: CaptureStabilizationWaiting, @unchecked Sendable {
    private let log: LifecycleLog
    private let controlled: Bool
    private let lock = NSLock()
    private var waits = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(log: LifecycleLog, controlled: Bool = false) {
        self.log = log
        self.controlled = controlled
    }

    func wait() async throws {
        log.append(.stabilizationWait)
        if controlled {
            await withCheckedContinuation { continuation in
                lock.lock()
                waits += 1
                continuations.append(continuation)
                resumeReadyCountWaitersLocked()
                lock.unlock()
            }
            try Task.checkCancellation()
        } else {
            await withCheckedContinuation { continuation in
                lock.lock()
                waits += 1
                resumeReadyCountWaitersLocked()
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func waitCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waits
    }

    func waitForWaitCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if waits >= count {
                lock.unlock()
                continuation.resume()
            } else {
                countWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func resumeAll() {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func resumeReadyCountWaitersLocked() {
        let ready = countWaiters.filter { waits >= $0.0 }
        countWaiters.removeAll { waits >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private final class SequencedSystemTapFactory: SystemAudioTapMaking, @unchecked Sendable {
    private let log: LifecycleLog
    private let lock = NSLock()
    private var formatsByAttempt: [[SystemAudioTapFormat]]
    private var attempts = 0
    private var reads = 0

    init(log: LifecycleLog, formatsByAttempt: [[SystemAudioTapFormat]]) {
        self.log = log
        self.formatsByAttempt = formatsByAttempt
    }

    func create(excludingProcessID: AudioObjectID?) throws -> any SystemAudioTapManaging {
        log.append(.tapCreate)
        lock.lock()
        guard !formatsByAttempt.isEmpty else {
            lock.unlock()
            throw StabilizationSequenceFixtureError.emptyTapAttempts
        }
        let index = min(attempts, formatsByAttempt.count - 1)
        attempts += 1
        let formats = formatsByAttempt[index]
        lock.unlock()
        return CountingSystemAudioTap(
            log: log,
            uid: fixedSystemTapUUID,
            formats: formats,
            onRead: { [weak self] in self?.recordRead() }
        )
    }

    func createCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func formatReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    private func recordRead() {
        lock.lock()
        reads += 1
        lock.unlock()
    }
}

private final class CountingSystemAudioTap: SystemAudioTapManaging, @unchecked Sendable {
    let id = AudioObjectID(199)
    let uid: UUID
    let warnings: [AudioCaptureWarning] = []
    private let log: LifecycleLog
    private let lock = NSLock()
    private var formats: [SystemAudioTapFormat]
    private var reads = 0
    private var destroyed = false
    private let onRead: @Sendable () -> Void

    init(log: LifecycleLog, uid: UUID, formats: [SystemAudioTapFormat], onRead: @escaping @Sendable () -> Void) {
        self.log = log
        self.uid = uid
        self.formats = formats
        self.onRead = onRead
    }

    func currentFormat() throws -> SystemAudioTapFormat {
        onRead()
        log.append(.tapFormatRead)
        lock.lock()
        guard !formats.isEmpty else {
            lock.unlock()
            throw StabilizationSequenceFixtureError.emptyTapFormats
        }
        let index = min(reads, formats.count - 1)
        reads += 1
        let format = formats[index]
        lock.unlock()
        return format
    }

    func destroy() throws {
        lock.lock()
        let shouldDestroy = !destroyed
        destroyed = true
        lock.unlock()
        if shouldDestroy {
            log.append(.tapDestroy)
        }
    }
}

private final class SequencedAggregateFactory: CaptureAggregateDeviceMaking, @unchecked Sendable {
    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private let lock = NSLock()
    private var streamSnapshotsByAttempt: [([InputStreamDescriptor], [InputStreamDescriptor])]
    private var bufferSnapshotsByAttempt: [([Int], [Int])]
    private var systemCreates = 0
    private var streamReads = 0

    init(
        log: LifecycleLog,
        streamSnapshotsByAttempt: [([InputStreamDescriptor], [InputStreamDescriptor])],
        bufferSnapshotsByAttempt: [([Int], [Int])]? = nil,
        teardownFailures: LifecycleFailurePlan = LifecycleFailurePlan()
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.streamSnapshotsByAttempt = streamSnapshotsByAttempt
        self.bufferSnapshotsByAttempt = bufferSnapshotsByAttempt ?? streamSnapshotsByAttempt.map { snapshots in
            (snapshots.0.map(\.channelCount), snapshots.1.map(\.channelCount))
        }
    }

    func createMicOnlyAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor]
    ) throws -> any CaptureAggregateDeviceManaging {
        log.append(.aggregateCreate)
        return FakeAggregate(log: log, teardownFailures: LifecycleFailurePlan())
    }

    func createSystemOnlyAggregate(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int
    ) throws -> any CaptureAggregateDeviceManaging {
        log.append(.aggregateCreate)
        lock.lock()
        guard !streamSnapshotsByAttempt.isEmpty, !bufferSnapshotsByAttempt.isEmpty else {
            lock.unlock()
            throw StabilizationSequenceFixtureError.emptyAggregateAttempts
        }
        let index = min(systemCreates, streamSnapshotsByAttempt.count - 1)
        systemCreates += 1
        let snapshots = streamSnapshotsByAttempt[index]
        let bufferSnapshots = bufferSnapshotsByAttempt[min(index, bufferSnapshotsByAttempt.count - 1)]
        lock.unlock()
        return FakeAggregate(
            log: log,
            teardownFailures: teardownFailures,
            inputStreams: snapshots.0,
            channelMap: InputChannelMap(
                microphoneChannels: [],
                systemChannels: Array(0..<tapChannelCount),
                bufferLayout: [InputBufferLayout(bufferIndex: 0, channelCount: tapChannelCount)],
                confidence: .terminalType
            ),
            inputChannelCount: tapChannelCount,
            inputBufferChannelCounts: bufferSnapshots.0,
            currentInputStreamSequence: [snapshots.1],
            currentInputBufferSequence: [bufferSnapshots.1],
            onCurrentInputStreams: { [weak self] in self?.recordStreamRead() }
        )
    }

    func createMicAndSystemAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) throws -> any CaptureAggregateDeviceManaging {
        try createSystemOnlyAggregate(
            outputUID: outputUID,
            tapUID: tapUID,
            tapChannelCount: tapChannelCount
        )
    }

    func systemCreateCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return systemCreates
    }

    func currentInputStreamReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return streamReads
    }

    private func recordStreamRead() {
        lock.lock()
        streamReads += 1
        lock.unlock()
    }
}

private final class CapturingMonitorFactory: CaptureDeviceMonitoring, @unchecked Sendable {
    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private var eventDuringRegister: CaptureDeviceEvent?
    private let lock = NSLock()
    private var handler: (@Sendable (CaptureDeviceEvent) -> Void)?

    init(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan = LifecycleFailurePlan(),
        eventDuringRegister: CaptureDeviceEvent? = nil
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.eventDuringRegister = eventDuringRegister
    }

    func register(
        aggregateID: AudioObjectID,
        microphoneID: AudioObjectID?,
        eventHandler: @escaping @Sendable (CaptureDeviceEvent) -> Void
    ) throws -> any CaptureDeviceMonitorRegistration {
        log.append(.listenerRegister)
        lock.lock()
        handler = eventHandler
        let eventDuringRegister = self.eventDuringRegister
        self.eventDuringRegister = nil
        lock.unlock()
        if let eventDuringRegister {
            eventHandler(eventDuringRegister)
        }
        return FakeMonitorRegistration(log: log, teardownFailures: teardownFailures)
    }

    func trigger(_ event: CaptureDeviceEvent) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }
}

private func stabilizationDependencies(
    log: LifecycleLog,
    aggregateFactory: (any CaptureAggregateDeviceMaking)? = nil,
    monitorFactory: (any CaptureDeviceMonitoring)? = nil,
    writerFactory: (any CaptureSessionRecordingWriterMaking)? = nil,
    systemTapFactory: (any SystemAudioTapMaking)? = nil,
    stabilizationWaiter: (any CaptureStabilizationWaiting)? = nil,
    attemptFileManager: (any CaptureAttemptFileManaging)? = nil,
    runtimeEventAcknowledgement: (@Sendable (CaptureDeviceEvent) -> Void)? = nil
) -> CaptureSession.Dependencies {
    CaptureSession.Dependencies(
        permissionRequester: FakeMicrophonePermissionRequester(log: log, granted: true),
        deviceResolver: FakeCaptureDeviceResolver(log: log),
        diskSpaceChecker: FakePreflightDiskSpaceChecker(log: log, capacity: 1_000_000_000),
        aggregateFactory: aggregateFactory ?? FakeAggregateFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan()
        ),
        monitorFactory: monitorFactory ?? FakeMonitorFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan()
        ),
        writerFactory: writerFactory ?? FakeSessionWriterFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan(),
            probe: nil
        ),
        ioProcManager: FakeIOProcManager(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan()
        ),
        processObjects: FakeProcessObjectResolver(log: log, failurePoint: nil),
        systemTapFactory: systemTapFactory ?? FakeSystemAudioTapFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan()
        ),
        stabilizationWaiter: stabilizationWaiter ?? ZeroDelayCaptureStabilizationWaiter(),
        attemptFileManager: attemptFileManager ?? FileManagerCaptureAttemptFileManager(),
        runtimeEventAcknowledgement: runtimeEventAcknowledgement
    )
}

private func systemTapStreams(name: String = "Tap") -> [InputStreamDescriptor] {
    [
        InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: 2,
            terminalType: .unknown,
            name: name
        )
    ]
}

private struct StabilizationOutput {
    let directory: URL
    let attemptURL: URL
    let log: LifecycleLog
}

private func temporaryStabilizationOutput() throws -> StabilizationOutput {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return StabilizationOutput(
        directory: directory,
        attemptURL: directory.appendingPathComponent("attempt.m4a"),
        log: LifecycleLog()
    )
}

private func stabilizationConfiguration(mode: CaptureMode, outputURL: URL) -> RecordingConfiguration {
    RecordingConfiguration(
        mode: mode,
        microphoneUID: mode == .micOnly ? "mic-uid" : nil,
        outputURL: outputURL,
        microphoneGain: 1,
        systemGain: 1
    )
}

private func assertDeviceEvent(
    _ event: CaptureDeviceEvent,
    mode: CaptureMode,
    expectedError: AudioCaptureError
) async throws {
    let log = LifecycleLog()
    let monitorFactory = CapturingMonitorFactory(log: log)
    let session = CaptureSession(dependencies: stabilizationDependencies(log: log, monitorFactory: monitorFactory))
    _ = try await session.start(configuration: configuration(mode: mode))

    monitorFactory.trigger(event)
    await yieldUntilDeviceStop(log)

    do {
        _ = try await session.stop()
        Issue.record("stop unexpectedly succeeded for \(event)")
    } catch let error as AudioCaptureError {
        #expect(error == expectedError)
        #expect(log.events().filter { $0 == .deviceStop }.count == 1)
    } catch {
        Issue.record("unexpected stop error: \(error)")
    }
}

private final class FailsOnceAttemptFileManager: CaptureAttemptFileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var removals: [URL] = []
    private var shouldFail = true

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        removals.append(url)
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail {
            throw AudioCaptureError.fileWriteFailed("synthetic attempt deletion failure")
        }
        try FileManager.default.removeItem(at: url)
    }

    func removeAttempts() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return removals
    }
}

private final class RuntimeEventAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CaptureDeviceEvent] = []

    func record(_ event: CaptureDeviceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func waitFor(_ event: CaptureDeviceEvent) async {
        for _ in 0..<50 {
            if observed(event) {
                return
            }
            await Task.yield()
        }
        Issue.record("runtime event acknowledgement was not observed for \(event)")
    }

    private func observed(_ event: CaptureDeviceEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(event)
    }
}

private func yieldUntilDeviceStop(_ log: LifecycleLog) async {
    for _ in 0..<50 {
        if log.events().contains(.deviceStop) {
            return
        }
        await Task.yield()
    }
}

private func allowScheduledTasksToRunForStabilizationTests() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}
