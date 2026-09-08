@testable import AudioPipeline
import CoreAudio
import Dispatch
import Foundation

struct FakeSessionWriterFactory: CaptureSessionRecordingWriterMaking {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    let teardownFailures: LifecycleFailurePlan
    let probe: FakeSessionWriterProbe?

    func makeWriter(
        inputSampleRate: Double,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        liveAudioHandler: LiveAudioSampleHandler?,
        diskSpaceChecker: any DiskSpaceChecking
    ) throws -> any CaptureSessionRecordingWriter {
        log.append(.writerMake)
        if failurePoint == .writerMake {
            throw AudioCaptureError.fileWriteFailed("synthetic make failure")
        }
        let writer = FakeSessionWriter(
            log: log,
            failurePoint: failurePoint,
            teardownFailures: teardownFailures,
            outputURL: outputURL
        )
        probe?.publish(writer)
        return writer
    }
}

final class FakeSessionWriter: CaptureSessionRecordingWriter, @unchecked Sendable {
    private let log: LifecycleLog
    private let failurePoint: StartFailurePoint?
    private let teardownFailures: LifecycleFailurePlan
    private let outputURL: URL
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var joined = false
    private var terminalResult: Result<FinishedRecordingOutput, Error>?
    private var completionHandler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?

    init(
        log: LifecycleLog,
        failurePoint: StartFailurePoint?,
        teardownFailures: LifecycleFailurePlan,
        outputURL: URL
    ) {
        self.log = log
        self.failurePoint = failurePoint
        self.teardownFailures = teardownFailures
        self.outputURL = outputURL
    }

    func start() throws {
        log.append(.writerStart)
        if failurePoint == .writerStart {
            throw AudioCaptureError.fileWriteFailed("synthetic start failure")
        }
        lock.lock()
        started = true
        lock.unlock()
    }

    func setCompletionHandler(_ handler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
    }

    func triggerRuntimeFailure(_ error: AudioCaptureError) {
        let result: Result<FinishedRecordingOutput, Error> = .failure(error)
        lock.lock()
        terminalResult = result
        let handler = completionHandler
        lock.unlock()
        handler?(result)
    }

    func requestStop() {
        lock.lock()
        let shouldStop = !joined
        stopped = true
        lock.unlock()
        if shouldStop {
            log.append(.writerRequestStop)
        }
    }

    func pause() throws -> RecordingSegmentOutput {
        log.append(.writerPause)
        return RecordingSegmentOutput(
            url: outputURL,
            duration: 0.25,
            outputFramesWritten: 12_000
        )
    }

    func resume(outputURL: URL) throws {
        log.append(.writerResume)
    }

    func join() throws -> FinishedRecordingOutput {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            log.append(.writerJoin)
            return try terminalResult.get()
        }
        let shouldJoin = !joined
        lock.unlock()
        if shouldJoin {
            log.append(.writerJoin)
        }
        if let error = teardownFailures.consumeFailure(at: .writerJoin) {
            throw error
        }
        lock.lock()
        joined = true
        lock.unlock()
        return FinishedRecordingOutput(
            url: outputURL,
            duration: 1,
            sampleRate: 48_000,
            channelCount: 2,
            bars: [],
            stats: RecordingWriterStats(
                inputFramesRead: 48_000,
                outputFramesWritten: 48_000,
                fileWriteCalls: 1,
                barsEmitted: 0,
                ringDroppedFrames: 0,
                ringOverflowCount: 0,
                microphonePeak: 0,
                systemPeak: 0
            ),
            warnings: []
        )
    }
}

struct FakeIOProcManager: CaptureDeviceIOProcManaging {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    let teardownFailures: LifecycleFailurePlan

    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue,
        block: @escaping AudioDeviceIOBlock
    ) throws -> AudioDeviceIOProcID {
        log.append(.ioProcCreate)
        if failurePoint == .ioProcCreate {
            throw AudioCaptureError.ioProcCreationFailed(-50)
        }
        return fakeAudioDeviceIOProc
    }

    func startDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.deviceStart)
        if failurePoint == .deviceStart {
            throw AudioCaptureError.startFailed(-50)
        }
    }

    func stopDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.deviceStop)
        if let error = teardownFailures.consumeFailure(at: .deviceStop) {
            throw error
        }
    }

    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.ioProcDestroy)
        if let error = teardownFailures.consumeFailure(at: .ioProcDestroy) {
            throw error
        }
    }
}
