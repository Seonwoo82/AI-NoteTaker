import CoreAudio
import Dispatch
import Foundation

struct CaptureResolvedMicrophone: Sendable {
    let id: AudioObjectID
    let uid: String
    let inputStreams: [InputStreamDescriptor]
}

struct CaptureResolvedOutput: Sendable {
    let id: AudioObjectID
    let uid: String
}

protocol CaptureDeviceResolving: Sendable {
    func resolveMicrophone(uid: String?) throws -> CaptureResolvedMicrophone
    func resolveDefaultOutput() throws -> CaptureResolvedOutput
}

protocol CaptureSessionRecordingWriter: AnyObject, Sendable {
    var currentProgress: CaptureProgress? { get }
    func start() throws
    func setCompletionHandler(_ handler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?)
    func pause() throws -> RecordingSegmentOutput
    func resume(outputURL: URL) throws
    func requestStop()
    func join() throws -> FinishedRecordingOutput
}

extension CaptureSessionRecordingWriter {
    var currentProgress: CaptureProgress? { nil }
}

protocol CaptureSessionRecordingWriterMaking: Sendable {
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
    ) throws -> any CaptureSessionRecordingWriter
}

protocol CaptureDeviceIOProcManaging: Sendable {
    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue,
        block: @escaping AudioDeviceIOBlock
    ) throws -> AudioDeviceIOProcID

    func startDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws
    func stopDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws
    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws
}

extension RecordingWriter: CaptureSessionRecordingWriter {}

struct CoreAudioCaptureDeviceResolver: CaptureDeviceResolving {
    private let registry: AudioDeviceRegistry

    init(registry: AudioDeviceRegistry = AudioDeviceRegistry()) {
        self.registry = registry
    }

    func resolveMicrophone(uid: String?) throws -> CaptureResolvedMicrophone {
        let deviceID: AudioObjectID
        if let uid {
            deviceID = try registry.deviceID(forUID: uid)
        } else {
            deviceID = try registry.defaultInputDeviceID()
        }
        let resolvedUID = try registry.uid(forDeviceID: deviceID)
        let inputStreams = try registry.inputStreamDescriptors(for: deviceID)
        return CaptureResolvedMicrophone(id: deviceID, uid: resolvedUID, inputStreams: inputStreams)
    }

    func resolveDefaultOutput() throws -> CaptureResolvedOutput {
        let deviceID = try registry.defaultOutputDeviceID()
        let resolvedUID = try registry.uid(forDeviceID: deviceID)
        return CaptureResolvedOutput(id: deviceID, uid: resolvedUID)
    }
}

struct DefaultCaptureSessionRecordingWriterFactory: CaptureSessionRecordingWriterMaking {
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
        try RecordingWriter(
            inputSampleRate: inputSampleRate,
            inputChannelCount: inputChannelCount,
            layout: layout,
            ring: ring,
            wake: wake,
            outputURL: outputURL,
            microphoneGain: microphoneGain,
            systemGain: systemGain,
            liveAudioHandler: liveAudioHandler,
            diskSpaceChecker: diskSpaceChecker
        )
    }
}

struct CoreAudioDeviceIOProcManager: CaptureDeviceIOProcManaging {
    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue,
        block: @escaping AudioDeviceIOBlock
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, queue, block)
        guard status == kAudioHardwareNoError else {
            throw AudioCaptureError.ioProcCreationFailed(status)
        }
        guard let ioProcID else {
            throw AudioCaptureError.ioProcCreationFailed(kAudioHardwareUnspecifiedError)
        }
        return ioProcID
    }

    func startDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceStart(deviceID, ioProcID)
        guard status == kAudioHardwareNoError else {
            throw AudioCaptureError.startFailed(status)
        }
    }

    func stopDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceStop(deviceID, ioProcID)
        guard status == kAudioHardwareNoError else {
            throw CoreAudioError(status: status, operation: .stopDevice, objectID: deviceID, selector: nil)
        }
    }

    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        guard status == kAudioHardwareNoError else {
            throw CoreAudioError(status: status, operation: .destroyIOProc, objectID: deviceID, selector: nil)
        }
    }
}
