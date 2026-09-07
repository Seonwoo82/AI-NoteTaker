import CoreAudio
import Foundation

protocol AudioProcessObjectQuerying: Sendable {
    func primeHALClient() throws
    func translatePID(_ pid: pid_t) throws -> AudioObjectID
}

protocol AudioProcessObjectResolving: Sendable {
    func currentProcessObjectID() throws -> AudioObjectID?
}

public struct AudioProcessObjects: AudioProcessObjectResolving, Sendable {
    private let query: any AudioProcessObjectQuerying

    public init() {
        self.query = SystemAudioProcessObjectQuery()
    }

    init(query: any AudioProcessObjectQuerying) {
        self.query = query
    }

    public func processObjectID(for pid: pid_t) throws -> AudioObjectID? {
        try query.primeHALClient()
        let objectID = try query.translatePID(pid)
        guard objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    public func currentProcessObjectID() throws -> AudioObjectID? {
        try processObjectID(for: getpid())
    }
}

typealias AudioObjectPropertyDataGetting = @Sendable (
    _ objectID: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>,
    _ qualifierDataSize: UInt32,
    _ qualifierData: UnsafeRawPointer?,
    _ ioDataSize: UnsafeMutablePointer<UInt32>,
    _ outData: UnsafeMutableRawPointer
) -> OSStatus

struct SystemAudioProcessObjectQuery: AudioProcessObjectQuerying {
    private let getPropertyData: AudioObjectPropertyDataGetting

    init(getPropertyData: @escaping AudioObjectPropertyDataGetting = AudioObjectGetPropertyData) {
        self.getPropertyData = getPropertyData
    }

    func primeHALClient() throws {
        _ = try CoreAudioProperty.getArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            as: UInt32.self
        )
    }

    func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var mutablePID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var ioDataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &mutablePID) { pidPointer in
            getPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &ioDataSize,
                &processObjectID
            )
        }
        try CoreAudioProperty.check(
            status,
            operation: .getData,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address
        )
        try CoreAudioProperty.validateScalarSize(
            ioDataSize,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            as: AudioObjectID.self,
            operation: .getData
        )
        return processObjectID
    }
}
