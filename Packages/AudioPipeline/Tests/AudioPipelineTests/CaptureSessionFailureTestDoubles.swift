@testable import AudioPipeline
import Foundation

enum TeardownFailurePoint: CaseIterable, Equatable, Sendable {
    case listenerRemove
    case deviceStop
    case ioProcDestroy
    case writerJoin
    case aggregateDestroy
    case tapDestroy

    static var allCasesWithoutTap: [TeardownFailurePoint] {
        allCases.filter { $0 != .tapDestroy }
    }

    var error: AudioCaptureError {
        switch self {
        case .listenerRemove: .deviceDisconnected
        case .deviceStop: .ioStoppedAbnormally
        case .ioProcDestroy: .ioProcCreationFailed(-51)
        case .writerJoin: .fileWriteFailed("synthetic join failure")
        case .aggregateDestroy: .aggregateCreationFailed(-52)
        case .tapDestroy: .tapCreationFailed(-53)
        }
    }
}

final class LifecycleFailurePlan: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: [TeardownFailurePoint: Int]

    init(_ points: [TeardownFailurePoint] = []) {
        remainingFailures = Dictionary(uniqueKeysWithValues: points.map { ($0, 1) })
    }

    func consumeFailure(at point: TeardownFailurePoint) -> AudioCaptureError? {
        lock.lock()
        defer { lock.unlock() }
        guard let remaining = remainingFailures[point], remaining > 0 else {
            return nil
        }
        remainingFailures[point] = remaining - 1
        return point.error
    }
}

final class ControlledPermissionRequester: MicrophonePermissionRequesting, @unchecked Sendable {
    private let log: LifecycleLog
    private let lock = NSLock()
    private var requestCount = 0
    private var duplicateRequest = false
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(log: LifecycleLog) {
        self.log = log
    }

    func requestRecordPermission() async -> Bool {
        log.append(.permission)
        return await withCheckedContinuation { continuation in
            lock.lock()
            requestCount += 1
            if !continuations.isEmpty {
                duplicateRequest = true
                resumeReadyWaitersLocked()
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            continuations.append(continuation)
            resumeReadyWaitersLocked()
            lock.unlock()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requestCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func resumeAll(granting granted: Bool) {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: granted)
        }
    }

    func observedDuplicateRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return duplicateRequest
    }

    private func resumeReadyWaitersLocked() {
        let ready = waiters.filter { requestCount >= $0.0 }
        waiters.removeAll { requestCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

final class FakeSessionWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: FakeSessionWriter?

    func publish(_ writer: FakeSessionWriter) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    func requireWriter() throws -> FakeSessionWriter {
        lock.lock()
        defer { lock.unlock() }
        guard let writer else {
            throw AudioCaptureError.fileWriteFailed("writer unavailable")
        }
        return writer
    }
}


final class FailsOnceCaptureDeviceResolver: CaptureDeviceResolving, @unchecked Sendable {
    private let log: LifecycleLog
    private let lock = NSLock()
    private var shouldFail = true

    init(log: LifecycleLog) {
        self.log = log
    }

    func resolveMicrophone(uid: String?) throws -> CaptureResolvedMicrophone {
        log.append(.resolveMicrophone)
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail {
            throw AudioCaptureError.deviceDisconnected
        }
        return CaptureResolvedMicrophone(
            id: 11,
            uid: uid ?? "default-mic",
            inputStreams: [micStream]
        )
    }

    func resolveDefaultOutput() throws -> CaptureResolvedOutput {
        log.append(.resolveOutput)
        return CaptureResolvedOutput(id: 12, uid: "default-output")
    }
}

final class MutableFakePreflightDiskSpaceChecker: DiskSpaceChecking, @unchecked Sendable {
    private let log: LifecycleLog
    private let lock = NSLock()
    private var capacity: Int64

    init(log: LifecycleLog, capacity: Int64) {
        self.log = log
        self.capacity = capacity
    }

    func setCapacity(_ capacity: Int64) {
        lock.lock()
        self.capacity = capacity
        lock.unlock()
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        log.append(.diskPreflight)
        lock.lock()
        defer { lock.unlock() }
        return capacity
    }
}
