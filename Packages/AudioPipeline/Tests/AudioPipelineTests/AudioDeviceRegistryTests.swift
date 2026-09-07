@testable import AudioPipeline
import CoreAudio
import Testing

@Test("Audio device registry maps unknown default input device to typed not found")
func audioDeviceRegistryMapsUnknownDefaultInputDeviceToTypedNotFound() {
    let reader = RegistryFakeReader()
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    reader.uint32s[.init(
        systemObject,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    )] = AudioObjectID(kAudioObjectUnknown)

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(throws: AudioCaptureError.deviceNotFound(uid: nil)) {
        _ = try registry.defaultInputDeviceID()
    }
}

@Test("AudioProcessObjects default output registry maps unknown device to typed not found")
func audioProcessObjectsDefaultOutputDeviceRegistryMapsUnknownDeviceToTypedNotFound() {
    let reader = RegistryFakeReader()
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    reader.uint32s[.init(
        systemObject,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    )] = AudioObjectID(kAudioObjectUnknown)

    let unknownOutputRegistry = AudioDeviceRegistry(reader: reader)

    #expect(throws: AudioCaptureError.deviceNotFound(uid: nil)) {
        _ = try unknownOutputRegistry.defaultOutputDeviceID()
    }
    #expect(reader.uint32Reads == [
        .init(
            systemObject,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
    ])
}

@Test("Audio device registry maps unknown UID translation to typed not found with UID")
func audioDeviceRegistryMapsUnknownUIDTranslationToTypedNotFoundWithUID() {
    let reader = RegistryFakeReader()
    reader.deviceIDsByUID["missing-device"] = AudioObjectID(kAudioObjectUnknown)

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(throws: AudioCaptureError.deviceNotFound(uid: "missing-device")) {
        _ = try registry.deviceID(forUID: "missing-device")
    }
}

@Test("Audio device registry assembles input devices from exact global and input properties")
func audioDeviceRegistryAssemblesInputDevicesFromExactProperties() throws {
    let reader = RegistryFakeReader()
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    reader.audioObjectIDArrays[.init(
        systemObject,
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(11), AudioObjectID(12)]
    reader.bufferChannelCounts[.init(
        11,
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [1, 1]
    reader.bufferChannelCounts[.init(
        12,
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = []
    reader.strings[.init(11, kAudioDevicePropertyDeviceUID)] = "built-in-mic"
    reader.strings[.init(11, kAudioObjectPropertyName)] = "Built-in Microphone"
    reader.uint32s[.init(11, kAudioDevicePropertyTransportType)] = kAudioDeviceTransportTypeBuiltIn

    let registry = AudioDeviceRegistry(reader: reader)

    let devices = try registry.inputDevices()

    #expect(devices == [
        AudioDeviceInfo(
            id: 11,
            uid: "built-in-mic",
            name: "Built-in Microphone",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            inputChannelCount: 2
        )
    ])
}

@Test("Audio device registry normalizes Core Audio one based stream channels to zero based descriptors")
func audioDeviceRegistryNormalizesOneBasedStreamChannelsToZeroBasedDescriptors() throws {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(201), AudioObjectID(202)]
    reader.uint32s[.init(201, kAudioStreamPropertyStartingChannel)] = UInt32(1)
    reader.uint32s[.init(202, kAudioStreamPropertyStartingChannel)] = UInt32(3)
    reader.streamDescriptions[.init(201, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 2)
    reader.streamDescriptions[.init(202, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 1)
    reader.uint32s[.init(201, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeMicrophone
    reader.uint32s[.init(202, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeHeadsetMicrophone
    reader.strings[.init(201, kAudioObjectPropertyName)] = "Mic left/right"
    reader.strings[.init(202, kAudioObjectPropertyName)] = "Headset boom"

    let registry = AudioDeviceRegistry(reader: reader)

    let descriptors = try registry.inputStreamDescriptors(for: 77)

    #expect(descriptors == [
        InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: 2,
            terminalType: .microphone,
            name: "Mic left/right"
        ),
        InputStreamDescriptor(
            bufferIndex: 1,
            startingChannelIndex: 2,
            channelCount: 1,
            terminalType: .headset,
            name: "Headset boom"
        )
    ])
}

@Test("Audio device registry rebases aggregate input stream channels to first input stream")
func audioDeviceRegistryRebasesAggregateInputStreamChannelsToFirstInputStream() throws {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(501), AudioObjectID(502)]
    reader.uint32s[.init(501, kAudioStreamPropertyStartingChannel)] = UInt32(7)
    reader.uint32s[.init(502, kAudioStreamPropertyStartingChannel)] = UInt32(9)
    reader.streamDescriptions[.init(501, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 2)
    reader.streamDescriptions[.init(502, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 1)
    reader.uint32s[.init(501, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeUnknown
    reader.uint32s[.init(502, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeLine
    reader.strings[.init(501, kAudioObjectPropertyName)] = ""
    reader.strings[.init(502, kAudioObjectPropertyName)] = "Line input"

    let registry = AudioDeviceRegistry(reader: reader)

    let descriptors = try registry.inputStreamDescriptors(for: 77)

    #expect(descriptors == [
        InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: 2,
            terminalType: .unknown,
            name: ""
        ),
        InputStreamDescriptor(
            bufferIndex: 1,
            startingChannelIndex: 2,
            channelCount: 1,
            terminalType: .line,
            name: "Line input"
        )
    ])
}

@Test("Audio device registry preserves real relative gaps after rebasing")
func audioDeviceRegistryPreservesRealRelativeGapsAfterRebasing() throws {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(511), AudioObjectID(512)]
    reader.uint32s[.init(511, kAudioStreamPropertyStartingChannel)] = UInt32(7)
    reader.uint32s[.init(512, kAudioStreamPropertyStartingChannel)] = UInt32(10)
    reader.streamDescriptions[.init(511, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 2)
    reader.streamDescriptions[.init(512, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 1)
    reader.uint32s[.init(511, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeMicrophone
    reader.uint32s[.init(512, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeUnknown
    reader.strings[.init(511, kAudioObjectPropertyName)] = "Mic"
    reader.strings[.init(512, kAudioObjectPropertyName)] = ""

    let registry = AudioDeviceRegistry(reader: reader)

    let descriptors = try registry.inputStreamDescriptors(for: 77)

    #expect(descriptors == [
        InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: 2,
            terminalType: .microphone,
            name: "Mic"
        ),
        InputStreamDescriptor(
            bufferIndex: 1,
            startingChannelIndex: 3,
            channelCount: 1,
            terminalType: .unknown,
            name: ""
        )
    ])
    #expect(throws: ChannelMapError.nonContiguousChannels) {
        _ = try ChannelMapResolver.resolve(
            aggregateStreams: descriptors,
            microphoneStreams: [],
            tapChannelCount: 1
        )
    }
}

@Test("Audio device registry treats missing stream name as optional unknown property")
func audioDeviceRegistryTreatsMissingStreamNameAsOptionalUnknownProperty() throws {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(401)]
    reader.uint32s[.init(401, kAudioStreamPropertyStartingChannel)] = UInt32(5)
    reader.streamDescriptions[.init(401, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 2)
    reader.uint32s[.init(401, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeLine
    reader.stringErrors[.init(401, kAudioObjectPropertyName)] = CoreAudioError(
        status: kAudioHardwareUnknownPropertyError,
        operation: .getDataSize,
        objectID: 401,
        selector: kAudioObjectPropertyName
    )

    let registry = AudioDeviceRegistry(reader: reader)

    let descriptors = try registry.inputStreamDescriptors(for: 77)

    #expect(descriptors == [
        InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: 2,
            terminalType: .line,
            name: ""
        )
    ])
}

@Test("Audio device registry propagates non unknown stream name errors unchanged")
func audioDeviceRegistryPropagatesNonUnknownStreamNameErrorsUnchanged() {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(402)]
    reader.uint32s[.init(402, kAudioStreamPropertyStartingChannel)] = UInt32(1)
    reader.streamDescriptions[.init(402, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 1)
    reader.uint32s[.init(402, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeMicrophone
    let expectedError = CoreAudioError(
        status: -12_345,
        operation: .getData,
        objectID: 402,
        selector: kAudioObjectPropertyName
    )
    reader.stringErrors[.init(402, kAudioObjectPropertyName)] = expectedError

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(throws: expectedError) {
        _ = try registry.inputStreamDescriptors(for: 77)
    }
}

@Test("Audio device registry rejects zero Core Audio stream starting channel")
func audioDeviceRegistryRejectsZeroCoreAudioStreamStartingChannel() {
    let reader = RegistryFakeReader()
    reader.audioObjectIDArrays[.init(
        77,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [AudioObjectID(301)]
    reader.uint32s[.init(301, kAudioStreamPropertyStartingChannel)] = UInt32(0)
    reader.streamDescriptions[.init(301, kAudioStreamPropertyVirtualFormat)] = audioDescription(channels: 1)
    reader.uint32s[.init(301, kAudioStreamPropertyTerminalType)] = kAudioStreamTerminalTypeMicrophone
    reader.strings[.init(301, kAudioObjectPropertyName)] = "Invalid stream"

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(throws: AudioDeviceRegistryError.invalidStartingChannel(streamID: 301, value: 0)) {
        _ = try registry.inputStreamDescriptors(for: 77)
    }
}

@Test("Audio device registry reads channel count and nominal sample rate without host enumeration")
func audioDeviceRegistryReadsChannelCountAndNominalSampleRateWithoutHostEnumeration() throws {
    let reader = RegistryFakeReader()
    reader.bufferChannelCounts[.init(
        88,
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [2, 4]
    reader.float64s[.init(88, kAudioDevicePropertyNominalSampleRate)] = Float64(48_000)

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(try registry.inputChannelCount(for: 88) == 6)
    #expect(try registry.nominalSampleRate(for: 88) == 48_000)
}

@Test("Audio device registry preserves input stream configuration buffer channel counts")
func audioDeviceRegistryPreservesInputStreamConfigurationBufferChannelCounts() throws {
    let reader = RegistryFakeReader()
    reader.bufferChannelCounts[.init(
        88,
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain
    )] = [1, 1]

    let registry = AudioDeviceRegistry(reader: reader)

    #expect(try registry.inputBufferChannelCounts(for: 88) == [1, 1])
}

private final class RegistryFakeReader: CoreAudioPropertyReading, @unchecked Sendable {
    var uint32s: [RegistryPropertyKey: UInt32] = [:]
    var uint32Reads: [RegistryPropertyKey] = []
    var float64s: [RegistryPropertyKey: Float64] = [:]
    var streamDescriptions: [RegistryPropertyKey: AudioStreamBasicDescription] = [:]
    var audioObjectIDArrays: [RegistryPropertyKey: [AudioObjectID]] = [:]
    var strings: [RegistryPropertyKey: String] = [:]
    var stringErrors: [RegistryPropertyKey: CoreAudioError] = [:]
    var bufferChannelCounts: [RegistryPropertyKey: [Int]] = [:]
    var deviceIDsByUID: [String: AudioObjectID] = [:]

    func getUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        uint32Reads.append(RegistryPropertyKey(objectID, address))
        return try value(uint32s, objectID: objectID, address: address)
    }

    func getFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64 {
        try value(float64s, objectID: objectID, address: address)
    }

    func getAudioStreamBasicDescription(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription {
        try value(streamDescriptions, objectID: objectID, address: address)
    }

    func getAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        try value(audioObjectIDArrays, objectID: objectID, address: address)
    }

    func getString(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
        let key = RegistryPropertyKey(objectID, address)
        if let error = stringErrors[key] {
            throw error
        }
        guard let string = strings[key] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return string
    }

    func inputBufferChannelCounts(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int] {
        let key = RegistryPropertyKey(objectID, address)
        guard let counts = bufferChannelCounts[key] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return counts
    }

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        deviceIDsByUID[uid] ?? AudioObjectID(kAudioObjectUnknown)
    }

    private func value<T>(
        _ storage: [RegistryPropertyKey: T],
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> T {
        let key = RegistryPropertyKey(objectID, address)
        guard let value = storage[key] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return value
    }

    private func missingValue(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> CoreAudioError {
        CoreAudioError(
            status: kAudioHardwareUnknownPropertyError,
            operation: .getData,
            objectID: objectID,
            selector: address.mSelector
        )
    }
}

private struct RegistryPropertyKey: Hashable {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.objectID = objectID
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    init(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        self.init(objectID, address.mSelector, address.mScope, address.mElement)
    }
}

private func audioDescription(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: 0,
        mBytesPerPacket: channels * 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: channels * 4,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}
