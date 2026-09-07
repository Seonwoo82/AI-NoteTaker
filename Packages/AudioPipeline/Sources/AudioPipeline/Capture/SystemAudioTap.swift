import CoreAudio
import Foundation

public struct SystemAudioTapFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let formatID: AudioFormatID
    public let formatFlags: AudioFormatFlags
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let bytesPerFrame: UInt32
    public let channelCount: UInt32
    public let bitsPerChannel: UInt32

    public init(
        sampleRate: Double,
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelCount: UInt32,
        bitsPerChannel: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
    }
}

protocol SystemAudioTapManaging: AnyObject, Sendable {
    var id: AudioObjectID { get }
    var uid: UUID { get }
    var warnings: [AudioCaptureWarning] { get }

    func currentFormat() throws -> SystemAudioTapFormat
    func destroy() throws
}

protocol SystemAudioTapMaking: Sendable {
    func create(excludingProcessID: AudioObjectID?) throws -> any SystemAudioTapManaging
}

protocol CoreAudioProcessTapAPI: Sendable {
    func createProcessTap(description: CATapDescription) throws -> AudioObjectID
    func readTapFormat(objectID: AudioObjectID) throws -> AudioStreamBasicDescription
    func destroyProcessTap(_ objectID: AudioObjectID) throws
}

typealias AudioHardwareCreateProcessTapCalling = @Sendable (
    _ description: CATapDescription,
    _ outTapID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus

typealias AudioHardwareDestroyProcessTapCalling = @Sendable (_ objectID: AudioObjectID) -> OSStatus

struct SystemCoreAudioProcessTapAPI: CoreAudioProcessTapAPI {
    private let createProcessTapCall: AudioHardwareCreateProcessTapCalling
    private let destroyProcessTapCall: AudioHardwareDestroyProcessTapCalling

    init(
        createProcessTap: @escaping AudioHardwareCreateProcessTapCalling = AudioHardwareCreateProcessTap,
        destroyProcessTap: @escaping AudioHardwareDestroyProcessTapCalling = AudioHardwareDestroyProcessTap
    ) {
        self.createProcessTapCall = createProcessTap
        self.destroyProcessTapCall = destroyProcessTap
    }

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = createProcessTapCall(description, &tapID)
        guard status == kAudioHardwareNoError else {
            if status == kAudioDevicePermissionsError {
                throw AudioCaptureError.systemAudioPermissionDenied
            }
            throw AudioCaptureError.tapCreationFailed(status)
        }
        guard tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.tapCreationFailed(kAudioHardwareBadObjectError)
        }
        return tapID
    }

    func readTapFormat(objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try CoreAudioProperty.get(
            objectID: objectID,
            address: CoreAudioProperty.address(kAudioTapPropertyFormat),
            as: AudioStreamBasicDescription.self
        )
    }

    func destroyProcessTap(_ objectID: AudioObjectID) throws {
        let status = destroyProcessTapCall(objectID)
        guard status == kAudioHardwareNoError else {
            throw CoreAudioError(
                status: status,
                operation: .destroyTap,
                objectID: objectID,
                selector: nil
            )
        }
    }
}

public struct SystemAudioTapFactory: SystemAudioTapMaking {
    private let api: any CoreAudioProcessTapAPI
    private let makeUUID: @Sendable () -> UUID

    public init() {
        self.api = SystemCoreAudioProcessTapAPI()
        self.makeUUID = { UUID() }
    }

    init(
        api: any CoreAudioProcessTapAPI,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.api = api
        self.makeUUID = makeUUID
    }

    func create(excludingProcessID: AudioObjectID?) throws -> any SystemAudioTapManaging {
        let warnings: [AudioCaptureWarning]
        let excludedProcesses: [AudioObjectID]
        if let excludingProcessID {
            warnings = []
            excludedProcesses = [excludingProcessID]
        } else {
            warnings = [.selfExclusionUnavailable]
            excludedProcesses = []
        }

        let uid = makeUUID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = "NoteTaker System Audio Tap"
        description.uuid = uid
        description.muteBehavior = .unmuted
        description.isPrivate = true

        let id = try api.createProcessTap(description: description)
        return SystemAudioTap(id: id, uid: uid, warnings: warnings, api: api)
    }
}

private final class SystemAudioTap: SystemAudioTapManaging, @unchecked Sendable {
    let id: AudioObjectID
    let uid: UUID
    let warnings: [AudioCaptureWarning]

    private let api: any CoreAudioProcessTapAPI
    private let destroyLock = NSLock()
    private var destroyed = false

    init(
        id: AudioObjectID,
        uid: UUID,
        warnings: [AudioCaptureWarning],
        api: any CoreAudioProcessTapAPI
    ) {
        self.id = id
        self.uid = uid
        self.warnings = warnings
        self.api = api
    }

    func currentFormat() throws -> SystemAudioTapFormat {
        let asbd = try api.readTapFormat(objectID: id)
        return try Self.validate(asbd)
    }

    func destroy() throws {
        destroyLock.lock()
        defer { destroyLock.unlock() }

        guard !destroyed else { return }

        try api.destroyProcessTap(id)
        destroyed = true
    }

    deinit {
        try? destroy()
    }

    private static func validate(_ asbd: AudioStreamBasicDescription) throws -> SystemAudioTapFormat {
        guard asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFramesPerPacket == 1,
              asbd.mChannelsPerFrame == 2,
              asbd.mBitsPerChannel == 32 else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }

        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
        guard asbd.mFormatFlags & requiredFlags == requiredFlags else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }
        guard asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0 else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }
        guard asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }

        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytes: UInt32 = nonInterleaved ? 4 : 8
        guard asbd.mBytesPerFrame == expectedBytes,
              asbd.mBytesPerPacket == expectedBytes else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }

        return SystemAudioTapFormat(
            sampleRate: asbd.mSampleRate,
            formatID: asbd.mFormatID,
            formatFlags: asbd.mFormatFlags,
            bytesPerPacket: asbd.mBytesPerPacket,
            framesPerPacket: asbd.mFramesPerPacket,
            bytesPerFrame: asbd.mBytesPerFrame,
            channelCount: asbd.mChannelsPerFrame,
            bitsPerChannel: asbd.mBitsPerChannel
        )
    }
}
