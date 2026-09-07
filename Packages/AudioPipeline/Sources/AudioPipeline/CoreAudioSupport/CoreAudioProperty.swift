import CoreAudio
import Foundation

protocol CoreAudioReadablePropertyValue {}

extension UInt32: CoreAudioReadablePropertyValue {}
extension Float64: CoreAudioReadablePropertyValue {}
extension AudioStreamBasicDescription: CoreAudioReadablePropertyValue {}

public enum CoreAudioProperty {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T: CoreAudioReadablePropertyValue>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type
    ) throws -> T {
        let byteSize = try dataSize(objectID: objectID, address: address)
        try validateScalarSize(byteSize, objectID: objectID, address: address, as: T.self)

        var address = address
        var ioDataSize = byteSize
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &ioDataSize, storage)
        try check(status, operation: .getData, objectID: objectID, address: address)
        try validateScalarSize(ioDataSize, objectID: objectID, address: address, as: T.self, operation: .getData)
        return storage.load(as: T.self)
    }

    static func getArray<T: CoreAudioReadablePropertyValue>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type
    ) throws -> [T] {
        let byteSize = try dataSize(objectID: objectID, address: address)
        let count = try arrayCount(byteSize: byteSize, objectID: objectID, address: address, as: T.self)
        var address = address
        var ioDataSize = byteSize
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &ioDataSize, values)
        try check(status, operation: .getData, objectID: objectID, address: address)
        let actualCount = try arrayCountAfterRead(
            allocatedByteSize: byteSize,
            returnedByteSize: ioDataSize,
            objectID: objectID,
            address: address,
            as: T.self
        )
        return Array(UnsafeBufferPointer(start: values, count: actualCount))
    }

    public static func getString(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> String {
        let byteSize = try dataSize(objectID: objectID, address: address)
        try validateScalarSize(byteSize, objectID: objectID, address: address, as: Unmanaged<CFString>?.self)

        var address = address
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<Unmanaged<CFString>?>.alignment
        )
        defer { storage.deallocate() }
        var ioDataSize = byteSize

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &ioDataSize, storage)
        try check(status, operation: .getData, objectID: objectID, address: address)
        try validateScalarSize(
            ioDataSize,
            objectID: objectID,
            address: address,
            as: Unmanaged<CFString>?.self,
            operation: .getData
        )

        let unmanagedString = storage.load(as: Optional<Unmanaged<CFString>>.self)
        guard let unmanagedString else {
            throw sizeError(operation: .getData, objectID: objectID, address: address)
        }
        return unmanagedString.takeRetainedValue() as String
    }

    static func inputBufferChannelCounts(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int] {
        let byteSize = try dataSize(objectID: objectID, address: address)
        guard Int(byteSize) >= audioBufferListHeaderByteSize else {
            throw sizeError(operation: .getDataSize, objectID: objectID, address: address)
        }

        var address = address
        var ioDataSize = byteSize
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &ioDataSize, storage)
        try check(status, operation: .getData, objectID: objectID, address: address)
        return try parseInputBufferChannelCounts(
            from: storage,
            returnedByteCount: ioDataSize,
            allocatedByteCount: byteSize,
            objectID: objectID,
            address: address
        )
    }

    static func deviceID(forUID uid: String) throws -> AudioObjectID {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var ioDataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let cfUID = uid as CFString

        let status = withUnsafePointer(to: cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &ioDataSize,
                &deviceID
            )
        }
        try check(
            status,
            operation: .getData,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address
        )
        try validateScalarSize(
            ioDataSize,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            as: AudioObjectID.self,
            operation: .getData
        )
        return deviceID
    }

    static func validateScalarSize<T>(
        _ byteSize: UInt32,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type,
        operation: CoreAudioOperation = .getDataSize
    ) throws {
        guard byteSize == UInt32(MemoryLayout<T>.size), byteSize > 0 else {
            throw sizeError(operation: operation, objectID: objectID, address: address)
        }
    }

    static func arrayCount<T: CoreAudioReadablePropertyValue>(
        byteSize: UInt32,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type,
        operation: CoreAudioOperation = .getDataSize
    ) throws -> Int {
        let elementSize = UInt32(MemoryLayout<T>.stride)
        guard byteSize > 0, elementSize > 0, byteSize.isMultiple(of: elementSize) else {
            throw sizeError(operation: operation, objectID: objectID, address: address)
        }
        return Int(byteSize / elementSize)
    }

    static func arrayCountAfterRead<T: CoreAudioReadablePropertyValue>(
        allocatedByteSize: UInt32,
        returnedByteSize: UInt32,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type
    ) throws -> Int {
        guard returnedByteSize <= allocatedByteSize else {
            throw sizeError(operation: .getData, objectID: objectID, address: address)
        }
        return try arrayCount(
            byteSize: returnedByteSize,
            objectID: objectID,
            address: address,
            as: T.self,
            operation: .getData
        )
    }

    static var audioBufferListHeaderByteSize: Int {
        MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    }

    static func audioBufferListByteSize(bufferCount: Int) -> Int {
        checkedAudioBufferListByteSize(bufferCount: bufferCount) ?? Int.max
    }

    static func parseInputBufferChannelCounts(
        from storage: UnsafeRawPointer,
        returnedByteCount: UInt32,
        allocatedByteCount: UInt32,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int] {
        guard returnedByteCount <= allocatedByteCount else {
            throw sizeError(operation: .getData, objectID: objectID, address: address)
        }

        let returnedByteCount = Int(returnedByteCount)
        let allocatedByteCount = Int(allocatedByteCount)
        guard returnedByteCount >= audioBufferListHeaderByteSize else {
            throw sizeError(operation: .getData, objectID: objectID, address: address)
        }

        let bufferCount = Int(storage.load(as: UInt32.self))
        guard let requiredByteCount = checkedAudioBufferListByteSize(bufferCount: bufferCount),
              requiredByteCount >= audioBufferListHeaderByteSize,
              requiredByteCount <= returnedByteCount,
              requiredByteCount <= allocatedByteCount else {
            throw sizeError(operation: .getData, objectID: objectID, address: address)
        }
        guard bufferCount > 0 else { return [] }

        let buffers = storage
            .advanced(by: audioBufferListHeaderByteSize)
            .bindMemory(to: AudioBuffer.self, capacity: bufferCount)
        return (0..<bufferCount).map { index in
            Int(buffers[index].mNumberChannels)
        }
    }

    private static func checkedAudioBufferListByteSize(bufferCount: Int) -> Int? {
        guard bufferCount >= 0 else { return nil }
        let (tailByteCount, tailOverflow) = bufferCount.multipliedReportingOverflow(
            by: MemoryLayout<AudioBuffer>.stride
        )
        guard !tailOverflow else { return nil }
        let (byteCount, addOverflow) = audioBufferListHeaderByteSize.addingReportingOverflow(tailByteCount)
        guard !addOverflow else { return nil }
        return byteCount
    }

    static func check(
        _ status: OSStatus,
        operation: CoreAudioOperation,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws {
        guard status == kAudioHardwareNoError else {
            throw CoreAudioError(
                status: status,
                operation: operation,
                objectID: objectID,
                selector: address.mSelector
            )
        }
    }

    static func addPropertyListenerBlock(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
        try check(status, operation: .addListener, objectID: objectID, address: address)
    }

    static func removePropertyListenerBlock(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var address = address
        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
        try check(status, operation: .removeListener, objectID: objectID, address: address)
    }

    private static func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var address = address
        var byteSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteSize)
        try check(status, operation: .getDataSize, objectID: objectID, address: address)
        return byteSize
    }

    private static func sizeError(
        operation: CoreAudioOperation,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> CoreAudioError {
        CoreAudioError(
            status: kAudioHardwareBadPropertySizeError,
            operation: operation,
            objectID: objectID,
            selector: address.mSelector
        )
    }

}

extension InputTerminalType {
    init(coreAudioTerminalType terminalType: UInt32) {
        switch terminalType {
        case kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeReceiverMicrophone:
            self = .microphone
        case kAudioStreamTerminalTypeHeadsetMicrophone:
            self = .headset
        case kAudioStreamTerminalTypeLine:
            self = .line
        default:
            self = .unknown
        }
    }
}
