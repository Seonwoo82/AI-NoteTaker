@testable import AudioPipeline
import CoreAudio
import Testing

@Test("CaptureSession public stop retains aggregate parents until dependent cleanup succeeds")
func captureSessionPublicStopRetainsParentsAfterDependentFailures() async throws {
    let cases: [(TeardownFailurePoint, [LifecycleEvent])] = [
        (.listenerRemove, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin]),
        (.deviceStop, [.listenerRemove, .deviceStop, .writerRequestStop, .writerJoin]),
        (.ioProcDestroy, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin]),
        (.writerJoin, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy]),
        (.aggregateDestroy, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy]),
    ]

    for (point, expectedCleanup) in cases {
        let log = LifecycleLog()
        let session = CaptureSession(dependencies: .fake(
            log: log,
            teardownFailures: LifecycleFailurePlan([point])
        ))
        _ = try await session.start(configuration: configuration())

        do {
            _ = try await session.stop()
            Issue.record("stop unexpectedly succeeded for \(point)")
        } catch let error as AudioCaptureError {
            #expect(error == point.error)
            #expect(Array(log.events().suffix(expectedCleanup.count)) == expectedCleanup)
        } catch {
            Issue.record("unexpected error for \(point): \(error)")
        }
    }
}

@Test("CaptureSession public stop retries dependencies before destroying aggregate")
func captureSessionPublicStopRetriesDependenciesBeforeAggregate() async throws {
    let cases: [(TeardownFailurePoint, [LifecycleEvent])] = [
        (.listenerRemove, [.listenerRemove, .aggregateDestroy]),
        (.deviceStop, [.deviceStop, .ioProcDestroy, .aggregateDestroy]),
        (.ioProcDestroy, [.ioProcDestroy, .aggregateDestroy]),
        (.writerJoin, [.writerRequestStop, .writerJoin]),
        (.aggregateDestroy, [.aggregateDestroy])
    ]

    for (point, retryEvents) in cases {
        let log = LifecycleLog()
        let session = CaptureSession(dependencies: .fake(
            log: log,
            teardownFailures: LifecycleFailurePlan([point])
        ))
        _ = try await session.start(configuration: configuration())

        do {
            _ = try await session.stop()
            Issue.record("first stop unexpectedly succeeded for \(point)")
        } catch {
            let eventCountAfterFailure = log.events().count
            _ = try await session.stop()
            #expect(Array(log.events().dropFirst(eventCountAfterFailure)) == retryEvents)
        }
    }
}

@Test("CaptureSession tap teardown retains every parent until its dependencies succeed")
func captureSessionTapTeardownRetainsParentsAfterDependentFailures() async throws {
    let cases: [(TeardownFailurePoint, [LifecycleEvent])] = [
        (.listenerRemove, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin]),
        (.deviceStop, [.listenerRemove, .deviceStop, .writerRequestStop, .writerJoin]),
        (.ioProcDestroy, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin]),
        (.writerJoin, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy]),
        (.aggregateDestroy, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy]),
        (.tapDestroy, [.listenerRemove, .deviceStop, .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy]),
    ]

    for (point, expectedCleanup) in cases {
        let log = LifecycleLog()
        let teardownFailures = LifecycleFailurePlan([point])
        let session = CaptureSession(dependencies: .fake(log: log, teardownFailures: teardownFailures))
        var partial = try makeTapOwningPartial(log: log, teardownFailures: teardownFailures)

        do {
            _ = try await session.teardownForTest(&partial)
            Issue.record("teardown unexpectedly succeeded for \(point)")
        } catch let error as AudioCaptureError {
            #expect(error == point.error)
            #expect(log.events() == expectedCleanup)
        } catch {
            Issue.record("unexpected error for \(point): \(error)")
        }
    }
}

@Test("CaptureSession tap teardown retries dependencies before aggregate and tap parents")
func captureSessionTapTeardownRetriesDependenciesBeforeParents() async throws {
    let cases: [(TeardownFailurePoint, [LifecycleEvent])] = [
        (.listenerRemove, [.listenerRemove, .aggregateDestroy, .tapDestroy]),
        (.deviceStop, [.deviceStop, .ioProcDestroy, .aggregateDestroy, .tapDestroy]),
        (.ioProcDestroy, [.ioProcDestroy, .aggregateDestroy, .tapDestroy]),
        (.writerJoin, [.writerRequestStop, .writerJoin]),
        (.aggregateDestroy, [.aggregateDestroy, .tapDestroy]),
        (.tapDestroy, [.tapDestroy])
    ]

    for (point, retryEvents) in cases {
        let log = LifecycleLog()
        let teardownFailures = LifecycleFailurePlan([point])
        let session = CaptureSession(dependencies: .fake(log: log, teardownFailures: teardownFailures))
        var partial = try makeTapOwningPartial(log: log, teardownFailures: teardownFailures)

        do {
            _ = try await session.teardownForTest(&partial)
            Issue.record("first stop unexpectedly succeeded for \(point)")
        } catch {
            let eventCountAfterFailure = log.events().count
            _ = try await session.teardownForTest(&partial)
            #expect(Array(log.events().dropFirst(eventCountAfterFailure)) == retryEvents)
        }
    }
}

@Test("CaptureSession tap-owning teardown destroys tap after aggregate on success")
func captureSessionTapOwningTeardownDestroysTapAfterAggregateOnSuccess() async throws {
    let log = LifecycleLog()
    let teardownFailures = LifecycleFailurePlan()
    let session = CaptureSession(dependencies: .fake(log: log, teardownFailures: teardownFailures))
    var partial = try makeTapOwningPartial(log: log, teardownFailures: teardownFailures)

    _ = try await session.teardownForTest(&partial)

    #expect(log.events() == [
        .listenerRemove,
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy,
        .tapDestroy
    ])
}

@Test("CaptureSession ignores an older generation completion while a newer generation is active")
func captureSessionIgnoresOlderGenerationCompletionWhileNewerGenerationIsActive() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(log: log))

    _ = try await session.start(configuration: configuration())
    _ = try await session.stop()
    _ = try await session.start(configuration: configuration())

    let eventCountBeforeStaleCompletion = log.events().count
    await session.writerCompletedForTest(.failure(AudioCaptureError.diskSpaceLow), generation: 1)
    await allowScheduledTasksToRunForTeardownTests()

    #expect(Array(log.events().dropFirst(eventCountBeforeStaleCompletion)) == [])

    _ = try await session.stop()
    #expect(log.events().filter { $0 == .deviceStop }.count == 2)
}

@Test("CaptureSession installed writer completion handler carries its captured generation")
func captureSessionInstalledWriterCompletionHandlerCarriesCapturedGeneration() async throws {
    let log = LifecycleLog()
    let writerProbe = CapturingSessionWriterProbe()
    let session = CaptureSession(dependencies: .fakeWithWriterFactory(
        log: log,
        writerFactory: CapturingSessionWriterFactory(log: log, probe: writerProbe)
    ))

    _ = try await session.start(configuration: configuration())
    let firstWriter = try writerProbe.requireWriter()
    let staleHandler = try firstWriter.requireCompletionHandler()
    _ = try await session.stop()
    _ = try await session.start(configuration: configuration())

    let eventCountBeforeStaleCompletion = log.events().count
    staleHandler(.failure(AudioCaptureError.diskSpaceLow))
    await allowScheduledTasksToRunForTeardownTests()

    #expect(Array(log.events().dropFirst(eventCountBeforeStaleCompletion)) == [])

    _ = try await session.stop()
    #expect(log.events().filter { $0 == .deviceStop }.count == 2)
}

@Test("CaptureSession startup cleanup failure retains retryable resources and later surfaces original startup error")
func captureSessionStartupCleanupFailureRetainsRetryableResourcesAndOriginalError() async throws {
    let log = LifecycleLog()
    let teardownFailures = LifecycleFailurePlan([.listenerRemove])
    let session = CaptureSession(dependencies: .fakeWithWriterFactory(
        log: log,
        teardownFailures: teardownFailures,
        writerFactory: CapturingSessionWriterFactory(
            log: log,
            teardownFailures: teardownFailures,
            failFirstStart: true
        )
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("start unexpectedly succeeded")
    } catch let error as AudioCaptureError {
        #expect(error == AudioCaptureError.fileWriteFailed("synthetic start failure"))
        #expect(log.events().suffix(3) == [
            .listenerRemove,
            .writerRequestStop,
            .writerJoin
        ])
    } catch {
        Issue.record("unexpected startup error: \(error)")
    }

    let eventCountAfterStartupFailure = log.events().count
    do {
        _ = try await session.stop()
        Issue.record("cleanup retry unexpectedly succeeded")
    } catch let error as AudioCaptureError {
        #expect(error == AudioCaptureError.fileWriteFailed("synthetic start failure"))
        #expect(Array(log.events().dropFirst(eventCountAfterStartupFailure)) == [.listenerRemove, .aggregateDestroy])
    } catch {
        Issue.record("unexpected cleanup retry error: \(error)")
    }

    _ = try await session.start(configuration: configuration())
    _ = try await session.stop()
}

@Test("CaptureSession retains aggregate ownership carried by a creation cleanup failure")
func captureSessionRetainsOwnerAfterAggregateIntrospectionCleanupFailure() async throws {
    let log = LifecycleLog()
    let pendingOwner = FailsOncePendingAggregateOwner(log: log)
    let aggregateFactory = OwnerBearingAggregateFailureFactory(
        log: log,
        pendingOwner: pendingOwner
    )
    let session = CaptureSession(dependencies: .fake(
        log: log,
        aggregateFactory: aggregateFactory
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(pendingOwner.destroyCount() == 1)
        #expect(await session.hasPendingCleanup())
    } catch {
        Issue.record("unexpected start error: \(error)")
    }

    do {
        _ = try await session.stop()
        Issue.record("cleanup retry unexpectedly returned output")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(pendingOwner.destroyCount() == 2)
        #expect(!(await session.hasPendingCleanup()))
    } catch {
        Issue.record("unexpected cleanup retry error: \(error)")
    }
}

private func makeTapOwningPartial(
    log: LifecycleLog,
    teardownFailures: LifecycleFailurePlan
) throws -> CaptureSession.PartialResources {
    CaptureSession.PartialResources(
        aggregate: FakeAggregate(log: log, teardownFailures: teardownFailures),
        tap: FakeSystemAudioTap(
            log: log,
            teardownFailures: teardownFailures,
            uid: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000199"))
        ),
        monitor: FakeMonitorRegistration(log: log, teardownFailures: teardownFailures),
        writer: FakeSessionWriter(
            log: log,
            failurePoint: nil,
            teardownFailures: teardownFailures,
            outputURL: configuration().outputURL
        ),
        deviceID: 99,
        stopIOProcID: fakeAudioDeviceIOProc,
        destroyIOProcID: fakeAudioDeviceIOProc,
        deviceStarted: true
    )
}

private final class FailsOncePendingAggregateOwner: CaptureAggregateDeviceDestroying, @unchecked Sendable {
    private let log: LifecycleLog
    private let lock = NSLock()
    private var calls = 0

    init(log: LifecycleLog) {
        self.log = log
    }

    func destroy() throws {
        log.append(.aggregateDestroy)
        lock.lock()
        calls += 1
        let shouldFail = calls == 1
        lock.unlock()
        if shouldFail {
            throw AudioCaptureError.aggregateCreationFailed(-52)
        }
    }

    func destroyCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct OwnerBearingAggregateFailureFactory: CaptureAggregateDeviceMaking {
    let log: LifecycleLog
    let pendingOwner: any CaptureAggregateDeviceDestroying

    func createMicOnlyAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor]
    ) throws -> any CaptureAggregateDeviceManaging {
        try fail()
    }

    func createSystemOnlyAggregate(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int
    ) throws -> any CaptureAggregateDeviceManaging {
        try fail()
    }

    func createMicAndSystemAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) throws -> any CaptureAggregateDeviceManaging {
        try fail()
    }

    private func fail() throws -> Never {
        log.append(.aggregateCreate)
        throw CaptureAggregateCreationCleanupError(
            originalError: AudioCaptureError.unsupportedStreamFormat(nil),
            cleanupError: AudioCaptureError.aggregateCreationFailed(-52),
            pendingOwner: pendingOwner
        )
    }
}

extension CaptureSession {
    func teardownForTest(_ partial: inout PartialResources) throws -> FinishedRecordingOutput {
        try teardownPartial(&partial)
    }

    func writerCompletedForTest(
        _ result: Result<FinishedRecordingOutput, Error>,
        generation: UInt64
    ) async {
        await writerCompleted(result, generation: generation)
    }
}

private func allowScheduledTasksToRunForTeardownTests() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}
