import CoreAudio
import Foundation

public struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let inputChannelCount: Int

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        transportType: UInt32,
        inputChannelCount: Int
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.inputChannelCount = inputChannelCount
    }
}

public enum AudioDeviceRegistryError: Error, Equatable, Sendable {
    case invalidStartingChannel(streamID: AudioObjectID, value: UInt32)
}

protocol CoreAudioPropertyReading: Sendable {
    func getUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32

    func getFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64

    func getAudioStreamBasicDescription(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription

    func getAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID]

    func getString(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String

    func inputBufferChannelCounts(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int]

    func deviceID(forUID uid: String) throws -> AudioObjectID
}

public struct AudioDeviceRegistry: Sendable {
    private let reader: any CoreAudioPropertyReading

    public init() {
        self.reader = SystemCoreAudioPropertyReader()
    }

    init(reader: any CoreAudioPropertyReading) {
        self.reader = reader
    }

    public func defaultInputDeviceID() throws -> AudioObjectID {
        let id = try reader.getUInt32(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
        )
        return try requireKnownDevice(id, uid: nil)
    }

    public func defaultOutputDeviceID() throws -> AudioObjectID {
        let id = try reader.getUInt32(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        )
        return try requireKnownDevice(id, uid: nil)
    }

    public func deviceID(forUID uid: String) throws -> AudioObjectID {
        let id = try reader.deviceID(forUID: uid)
        return try requireKnownDevice(id, uid: uid)
    }

    public func uid(forDeviceID id: AudioObjectID) throws -> String {
        try reader.getString(
            objectID: id,
            address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
        )
    }

    public func inputDevices() throws -> [AudioDeviceInfo] {
        let deviceIDs = try reader.getAudioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        )

        var devices: [AudioDeviceInfo] = []
        devices.reserveCapacity(deviceIDs.count)
        for id in deviceIDs {
            let channelCount = try inputChannelCount(for: id)
            guard channelCount > 0 else { continue }
            devices.append(AudioDeviceInfo(
                id: id,
                uid: try uid(forDeviceID: id),
                name: try reader.getString(
                    objectID: id,
                    address: CoreAudioProperty.address(kAudioObjectPropertyName)
                ),
                transportType: try reader.getUInt32(
                    objectID: id,
                    address: CoreAudioProperty.address(kAudioDevicePropertyTransportType)
                ),
                inputChannelCount: channelCount
            ))
        }
        return devices
    }

    public func inputChannelCount(for id: AudioObjectID) throws -> Int {
        try inputBufferChannelCounts(for: id).reduce(0, +)
    }

    public func inputBufferChannelCounts(for id: AudioObjectID) throws -> [Int] {
        try reader.inputBufferChannelCounts(
            objectID: id,
            address: CoreAudioProperty.address(
                kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeInput
            )
        )
    }

    public func nominalSampleRate(for id: AudioObjectID) throws -> Double {
        try reader.getFloat64(
            objectID: id,
            address: CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        )
    }

    public func inputStreamDescriptors(for id: AudioObjectID) throws -> [InputStreamDescriptor] {
        let streams = try reader.getAudioObjectIDs(
            objectID: id,
            address: CoreAudioProperty.address(
                kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )

        let descriptors = try streams.enumerated().map { bufferIndex, streamID in
            let startingChannel: UInt32 = try reader.getUInt32(
                objectID: streamID,
                address: CoreAudioProperty.address(kAudioStreamPropertyStartingChannel)
            )
            guard startingChannel > 0 else {
                throw AudioDeviceRegistryError.invalidStartingChannel(
                    streamID: streamID,
                    value: startingChannel
                )
            }
            let format: AudioStreamBasicDescription = try reader.getAudioStreamBasicDescription(
                objectID: streamID,
                address: CoreAudioProperty.address(kAudioStreamPropertyVirtualFormat)
            )
            let terminalType: UInt32 = try reader.getUInt32(
                objectID: streamID,
                address: CoreAudioProperty.address(kAudioStreamPropertyTerminalType)
            )
            let name: String
            do {
                name = try reader.getString(
                    objectID: streamID,
                    address: CoreAudioProperty.address(kAudioObjectPropertyName)
                )
            } catch let error as CoreAudioError where error.status == kAudioHardwareUnknownPropertyError {
                name = ""
            }

            return InputStreamDescriptor(
                bufferIndex: bufferIndex,
                startingChannelIndex: Int(startingChannel) - 1,
                channelCount: Int(format.mChannelsPerFrame),
                terminalType: InputTerminalType(coreAudioTerminalType: terminalType),
                name: name
            )
        }
        guard let baseStartingChannelIndex = descriptors.map(\.startingChannelIndex).min() else {
            return []
        }
        return descriptors.map { descriptor in
            InputStreamDescriptor(
                bufferIndex: descriptor.bufferIndex,
                startingChannelIndex: descriptor.startingChannelIndex - baseStartingChannelIndex,
                channelCount: descriptor.channelCount,
                terminalType: descriptor.terminalType,
                name: descriptor.name
            )
        }
    }

    private func requireKnownDevice(_ id: AudioObjectID, uid: String?) throws -> AudioObjectID {
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.deviceNotFound(uid: uid)
        }
        return id
    }
}

private struct SystemCoreAudioPropertyReader: CoreAudioPropertyReading {
    func getUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        try CoreAudioProperty.get(objectID: objectID, address: address, as: UInt32.self)
    }

    func getFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64 {
        try CoreAudioProperty.get(objectID: objectID, address: address, as: Float64.self)
    }

    func getAudioStreamBasicDescription(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription {
        try CoreAudioProperty.get(
            objectID: objectID,
            address: address,
            as: AudioStreamBasicDescription.self
        )
    }

    func getAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        try CoreAudioProperty.getArray(objectID: objectID, address: address, as: UInt32.self)
    }

    func getString(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
        try CoreAudioProperty.getString(objectID: objectID, address: address)
    }

    func inputBufferChannelCounts(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int] {
        try CoreAudioProperty.inputBufferChannelCounts(objectID: objectID, address: address)
    }

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        try CoreAudioProperty.deviceID(forUID: uid)
    }
}
