@testable import AudioPipeline
import Foundation
import Testing

@Test("CaptureSession reserves starting state before awaiting microphone permission")
func captureSessionRejectsConcurrentStartBeforeSecondPermissionRequest() async throws {
    let log = LifecycleLog()
    let permissionRequester = ControlledPermissionRequester(log: log)
    let session = CaptureSession(dependencies: .fake(
        log: log,
        permissionRequester: permissionRequester
    ))

    let firstStart = Task {
        try await session.start(configuration: configuration())
    }
    await permissionRequester.waitForRequestCount(1)

    let secondStart = Task {
        try await session.start(configuration: configuration())
    }

    let observation = await observeSecondStart(secondStart, permissionRequester: permissionRequester)
    permissionRequester.resumeAll(granting: true)
    _ = try await firstStart.value

    switch observation {
    case let .failed(error as AudioCaptureError):
        #expect(error == .fileWriteFailed("Capture session already started"))
    case let .failed(error):
        Issue.record("unexpected second-start error: \(error)")
    case .requestedPermissionAgain:
        Issue.record("second start requested microphone permission while first start was pending")
    case .succeeded:
        Issue.record("second start unexpectedly succeeded")
    }

    #expect(log.events().filter { $0 == .permission }.count == 1)
    _ = try await session.stop()
}

@Test("CaptureSession cannot resurrect mic-only startup after stop wins during permission wait")
func captureSessionStopDuringPermissionWaitPreventsLateStartup() async throws {
    let log = LifecycleLog()
    let permissionRequester = ControlledPermissionRequester(log: log)
    let session = CaptureSession(dependencies: .fake(
        log: log,
        permissionRequester: permissionRequester
    ))
    let start = Task {
        try await session.start(configuration: configuration())
    }
    await permissionRequester.waitForRequestCount(1)

    do {
        _ = try await session.stop()
        Issue.record("stop unexpectedly succeeded during permission wait")
    } catch AudioCaptureError.fileWriteFailed("Capture session stopped during startup") {
    } catch {
        Issue.record("unexpected stop error: \(error)")
    }

    permissionRequester.resumeAll(granting: true)
    do {
        _ = try await start.value
        _ = try? await session.stop()
        Issue.record("permission completion resurrected a stopped capture")
    } catch AudioCaptureError.fileWriteFailed("Capture session stopped during startup") {
    } catch {
        Issue.record("unexpected start error after stop won: \(error)")
    }

    #expect(log.events() == [.permission])
}

@Test("denied permission result cannot erase a stop that already won startup")
func captureSessionLatePermissionDenialPreservesStopOutcome() async throws {
    let log = LifecycleLog()
    let permissionRequester = ControlledPermissionRequester(log: log)
    let session = CaptureSession(dependencies: .fake(
        log: log,
        permissionRequester: permissionRequester
    ))
    let start = Task {
        try await session.start(configuration: configuration())
    }
    await permissionRequester.waitForRequestCount(1)
    _ = try? await session.stop()

    permissionRequester.resumeAll(granting: false)
    do {
        _ = try await start.value
        Issue.record("late denial unexpectedly allowed startup")
    } catch AudioCaptureError.fileWriteFailed("Capture session stopped during startup") {
    } catch {
        Issue.record("late denial replaced the cached stop outcome: \(error)")
    }

    #expect(log.events() == [.permission])
}

@Test("CaptureSession stops HAL promptly when writer reports runtime failure")
func captureSessionStopsHALWhenWriterReportsRuntimeFailure() async throws {
    let log = LifecycleLog()
    let writerProbe = FakeSessionWriterProbe()
    let session = CaptureSession(dependencies: .fake(log: log, writerProbe: writerProbe))

    _ = try await session.start(configuration: configuration())
    let writer = try writerProbe.requireWriter()

    writer.triggerRuntimeFailure(.diskSpaceLow)
    await waitForLifecycleEvents(log, suffix: [
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy
    ])

    #expect(log.events().suffix(5) == [
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy
    ])

    do {
        _ = try await session.stop()
        Issue.record("stop unexpectedly succeeded after runtime writer failure")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(log.events().filter { $0 == .deviceStop }.count == 1)
    } catch {
        Issue.record("unexpected stop error: \(error)")
    }
}

@Test("CaptureSession exposes one terminal event for writer runtime failure")
func captureSessionExposesOneTerminalEventForWriterRuntimeFailure() async throws {
    let log = LifecycleLog()
    let writerProbe = FakeSessionWriterProbe()
    let session = CaptureSession(dependencies: .fake(log: log, writerProbe: writerProbe))
    let recorder = TerminalEventRecorder()
    await recorder.start(stream: session.terminalEventStream)

    _ = try await session.start(configuration: configuration())
    let writer = try writerProbe.requireWriter()

    writer.triggerRuntimeFailure(.diskSpaceLow)
    await recorder.waitForCount(1)

    #expect(await recorder.events() == [CaptureTerminalEvent(generation: 1, error: .diskSpaceLow)])
    do {
        _ = try await session.stop()
        Issue.record("stop unexpectedly succeeded after runtime writer failure")
    } catch AudioCaptureError.diskSpaceLow {
    } catch {
        Issue.record("unexpected stop error: \(error)")
    }
    await recorder.waitForStableCount(1)
    #expect(await recorder.events() == [CaptureTerminalEvent(generation: 1, error: .diskSpaceLow)])
    await recorder.cancel()
}

private func waitForLifecycleEvents(_ log: LifecycleLog, suffix: [LifecycleEvent]) async {
    for _ in 0..<100 {
        if log.events().suffix(suffix.count) == suffix {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for lifecycle suffix: \(suffix)")
}

private actor TerminalEventRecorder {
    private var recordedEvents: [CaptureTerminalEvent] = []
    private var task: Task<Void, Never>?

    func start(stream: AsyncStream<CaptureTerminalEvent>) {
        task = Task {
            for await event in stream {
                record(event)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func events() -> [CaptureTerminalEvent] {
        return recordedEvents
    }

    func waitForCount(_ count: Int) async {
        for _ in 0..<50 {
            if events().count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("terminal event count did not reach \(count); got \(events())")
    }

    func waitForStableCount(_ count: Int) async {
        for _ in 0..<10 {
            await Task.yield()
        }
        if events().count != count {
            Issue.record("terminal event count changed; expected \(count), got \(events())")
        }
    }

    private func record(_ event: CaptureTerminalEvent) {
        recordedEvents.append(event)
    }
}

private enum ConcurrentStartObservation {
    case failed(Error)
    case requestedPermissionAgain
    case succeeded
}

private func observeSecondStart(
    _ task: Task<CaptureStartResult, Error>,
    permissionRequester: ControlledPermissionRequester
) async -> ConcurrentStartObservation {
    do {
        _ = try await task.value
        return .succeeded
    } catch {
        if permissionRequester.observedDuplicateRequest() {
            return .requestedPermissionAgain
        }
        return .failed(error)
    }
}
