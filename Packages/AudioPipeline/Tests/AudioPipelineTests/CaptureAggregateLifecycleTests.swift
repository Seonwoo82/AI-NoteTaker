@testable import AudioPipeline
import CoreAudio
import Foundation
import Testing

@Test("Mixed aggregate maps HAL address gaps to packed input buffer channels")
func mixedAggregateMapsHALAddressGapsToPackedInputBufferChannels() throws {
    // Observed on Studio Display: mono mic at HAL channel 1, stereo tap at 5.
    // The actual IOProc buffer layout is still [1, 2], not six channels.
    let tap = InputStreamDescriptor(bufferIndex: 1, startingChannelIndex: 4,
        channelCount: 2, terminalType: .unknown, name: "")
    let registry = AggregateRegistryDouble(sampleRates: [77: 48_000],
        streamReads: [77: [micStream, tap]], inputBufferChannelCounts: [77: [1, 2]], uids: [:])
    let aggregate = try CaptureAggregateDevice.createMicAndSystem(
        microphoneUID: "studio-display-mic", microphoneStreams: [micStream],
        outputUID: "output", tapUID: UUID(), tapChannelCount: 2,
        registry: registry.registry, api: RetryableAggregateAPI(), readBufferFrameSize: { _ in 512 })
    #expect(aggregate.inputStreams.map(\.startingChannelIndex) == [0, 1])
    #expect(aggregate.inputChannelCount == 3)
    #expect(aggregate.channelMap.microphoneChannels == [0])
    #expect(aggregate.channelMap.systemChannels == [1, 2])
    #expect(try aggregate.currentInputStreams() == aggregate.inputStreams)
    #expect(try registry.registry.inputStreamDescriptors(for: 77).map(\.startingChannelIndex) == [0, 4])
}

@Test("CaptureAggregateDevice creates microphone clocked mic and system aggregate")
func captureAggregateDeviceCreatesMicrophoneClockedMicAndSystemAggregate() throws {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 48_000],
        streamReads: [77: [micStream, systemTapStreamForMixedAggregate]],
        uids: [:]
    )
    let tapID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    let aggregate = try CaptureAggregateDevice.createMicAndSystem(
        microphoneUID: "mic-uid",
        microphoneStreams: [micStream],
        outputUID: "default-output-uid",
        tapUID: tapID,
        tapChannelCount: 2,
        clockSource: .microphone,
        registry: registry.registry,
        api: api,
        readBufferFrameSize: { id in
            #expect(id == 77)
            return 512
        }
    )

    let properties = try #require(api.createdProperties.first)
    #expect(properties[kAudioAggregateDeviceNameKey] as? String == "NoteTaker Mic and System Aggregate")
    #expect((properties[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.seonwoo.notetaker.aggregate.mixed.") == true)
    #expect(properties[kAudioAggregateDeviceMainSubDeviceKey] as? String == "mic-uid")
    #expect(properties[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
    #expect(properties[kAudioAggregateDeviceIsStackedKey] as? Bool == false)
    #expect(properties[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
    expectHALSubDevices(properties, equal: [["uid": "mic-uid", "drift": true]])
    expectHALTaps(properties, equal: [["uid": tapID.uuidString, "drift": true]])

    #expect(aggregate.channelMap.microphoneChannels == [0])
    #expect(aggregate.channelMap.systemChannels == [1, 2])
    #expect(aggregate.inputChannelCount == 3)
    #expect(aggregate.sampleRate == 48_000)
}

@Test("CaptureAggregateDevice creates system only aggregate from output clocked tap composition")
func captureAggregateDeviceCreatesSystemOnlyAggregateFromOutputClockedTapComposition() throws {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [77: [systemTapStream]],
        uids: [:]
    )
    let tapID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    let aggregate = try CaptureAggregateDevice.createSystemOnly(
        outputUID: "default-output-uid",
        tapUID: tapID,
        tapChannelCount: 2,
        registry: registry.registry,
        api: api,
        readBufferFrameSize: { id in
            #expect(id == 77)
            return 512
        }
    )

    let properties = try #require(api.createdProperties.first)
    #expect(properties[kAudioAggregateDeviceNameKey] as? String == "NoteTaker System Audio Aggregate")
    #expect((properties[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.seonwoo.notetaker.aggregate.system.") == true)
    #expect(properties[kAudioAggregateDeviceMainSubDeviceKey] as? String == "default-output-uid")
    #expect(properties[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
    #expect(properties[kAudioAggregateDeviceIsStackedKey] as? Bool == false)
    #expect(properties[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
    expectHALSubDevices(properties, equal: [["uid": "default-output-uid", "drift": false]])
    expectHALTaps(properties, equal: [["uid": tapID.uuidString, "drift": true]])

    #expect(aggregate.channelMap.microphoneChannels == [])
    #expect(aggregate.channelMap.systemChannels == [0, 1])
    #expect(aggregate.inputChannelCount == 2)
    #expect(aggregate.sampleRate == 44_100)
}

@Test("CaptureAggregateDevice uses stream configuration for non-interleaved input buffer layout")
func captureAggregateDeviceUsesStreamConfigurationForNonInterleavedInputBufferLayout() throws {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [77: [systemTapStream]],
        inputBufferChannelCounts: [77: [1, 1]],
        uids: [:]
    )

    let aggregate = try CaptureAggregateDevice.createSystemOnly(
        outputUID: "default-output-uid",
        tapUID: UUID(),
        tapChannelCount: 2,
        registry: registry.registry,
        api: api,
        readBufferFrameSize: { _ in 512 }
    )

    #expect(aggregate.channelMap.bufferLayout == [
        InputBufferLayout(bufferIndex: 0, channelCount: 1),
        InputBufferLayout(bufferIndex: 1, channelCount: 1)
    ])
    #expect(aggregate.inputChannelCount == 2)
}

@Test("CaptureAggregateDevice rejects input buffer channels that do not match stream channels")
func captureAggregateDeviceRejectsInputBufferChannelsThatDoNotMatchStreamChannels() {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [77: [systemTapStream]],
        inputBufferChannelCounts: [77: [1]],
        uids: [:]
    )

    #expect(throws: ChannelMapError.aggregateChannelCountMismatch(expected: 2, actual: 1)) {
        _ = try CaptureAggregateDevice.createSystemOnly(
            outputUID: "default-output-uid",
            tapUID: UUID(),
            tapChannelCount: 2,
            registry: registry.registry,
            api: api,
            readBufferFrameSize: { _ in 512 }
        )
    }
}

@Test("CaptureAggregateDevice currentInputStreams performs a live aggregate registry read")
func captureAggregateDeviceCurrentInputStreamsPerformsLiveAggregateRegistryRead() throws {
    let api = RetryableAggregateAPI()
    let refreshedDescriptors = [refreshedSystemTapStream]
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [77: [systemTapStream], 177: refreshedDescriptors],
        uids: [:]
    )

    let aggregate = try CaptureAggregateDevice.createSystemOnly(
        outputUID: "default-output-uid",
        tapUID: UUID(),
        tapChannelCount: 2,
        registry: registry.registry,
        api: api,
        readBufferFrameSize: { _ in 512 }
    )
    registry.streamReads[77] = refreshedDescriptors

    #expect(try aggregate.currentInputStreams() == refreshedDescriptors)
    #expect(registry.streamReadIDs == [77, 77])
}

@Test("CaptureAggregateDevice destroys newly created aggregate when system introspection fails")
func captureAggregateDeviceDestroysNewAggregateWhenSystemIntrospectionFails() {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [:],
        uids: [:]
    )

    #expect(throws: CoreAudioError.self) {
        _ = try CaptureAggregateDevice.createSystemOnly(
            outputUID: "default-output-uid",
            tapUID: UUID(),
            tapChannelCount: 2,
            registry: registry.registry,
            api: api,
            readBufferFrameSize: { _ in 512 }
        )
    }
    #expect(api.destroyCalls == [77])
}

@Test("aggregate introspection failure carries ownership when immediate destroy also fails")
func captureAggregateDeviceCarriesOwnerAfterIntrospectionAndDestroyFailure() throws {
    let api = RetryableAggregateAPI()
    api.failNextDestroy()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 44_100],
        streamReads: [:],
        uids: [:]
    )

    do {
        _ = try CaptureAggregateDevice.createSystemOnly(
            outputUID: "default-output-uid",
            tapUID: UUID(),
            tapChannelCount: 2,
            registry: registry.registry,
            api: api,
            readBufferFrameSize: { _ in 512 }
        )
        Issue.record("aggregate creation unexpectedly succeeded")
    } catch let failure as CaptureAggregateCreationCleanupError {
        #expect(failure.originalError is CoreAudioError)
        #expect(api.destroyCalls == [77])
        try failure.pendingOwner.destroy()
        #expect(api.destroyCalls == [77, 77])
    } catch {
        Issue.record("cleanup ownership was lost behind unexpected error: \(error)")
    }
}

@Test("CoreAudioCaptureDeviceResolver resolves default output ID and UID without reading input devices")
func coreAudioCaptureDeviceResolverResolvesDefaultOutputIDAndUID() throws {
    let registry = AggregateRegistryDouble(
        sampleRates: [:],
        streamReads: [:],
        uids: [55: "speaker-uid"],
        defaultOutputID: 55
    )
    let resolver = CoreAudioCaptureDeviceResolver(registry: registry.registry)

    let output = try resolver.resolveDefaultOutput()

    #expect(output.id == 55)
    #expect(output.uid == "speaker-uid")
    #expect(registry.defaultOutputReads == 1)
    #expect(registry.uidReadIDs == [55])
}

@Test("CaptureAggregateDevice mic only construction keeps previous channel map")
func captureAggregateDeviceMicOnlyConstructionKeepsPreviousChannelMap() throws {
    let api = RetryableAggregateAPI()
    let registry = AggregateRegistryDouble(
        sampleRates: [77: 48_000],
        streamReads: [77: [micStream]],
        uids: [:]
    )

    let aggregate = try CaptureAggregateDevice.createMicOnly(
        microphoneUID: "mic-uid",
        microphoneStreams: [micStream],
        registry: registry.registry,
        api: api,
        readBufferFrameSize: { _ in 512 }
    )

    #expect(aggregate.channelMap == micOnlyChannelMap)
    #expect(aggregate.inputChannelCount == 1)
}

@Test("CaptureAggregateDevice retries destroy after Core Audio failure")
func captureAggregateDeviceRetriesDestroyAfterFailure() throws {
    let api = RetryableAggregateAPI()
    let aggregate = CaptureAggregateDevice(
        id: 77,
        uid: "com.seonwoo.notetaker.tests.retryable-aggregate",
        sampleRate: 48_000,
        inputStreams: [micStream],
        channelMap: micOnlyChannelMap,
        inputChannelCount: 1,
        bufferFrameSize: 512,
        api: api
    )

    api.failNextDestroy()

    do {
        try aggregate.destroy()
        Issue.record("destroy unexpectedly succeeded")
    } catch AudioCaptureError.aggregateCreationFailed(-52) {
        #expect(api.destroyCalls == [77])
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    try aggregate.destroy()

    #expect(api.destroyCalls == [77, 77])
}

private final class RetryableAggregateAPI: CoreAudioAggregateDeviceAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailDestroy = false
    private(set) var createdProperties: [[String: Any]] = []
    private(set) var destroyCalls: [AudioObjectID] = []

    func failNextDestroy() {
        lock.lock()
        shouldFailDestroy = true
        lock.unlock()
    }

    func createAggregateDevice(properties: [String: Any]) throws -> AudioObjectID {
        createdProperties.append(properties)
        return 77
    }

    func destroyAggregateDevice(_ id: AudioObjectID) throws {
        lock.lock()
        destroyCalls.append(id)
        let shouldFail = shouldFailDestroy
        shouldFailDestroy = false
        lock.unlock()
        if shouldFail {
            throw AudioCaptureError.aggregateCreationFailed(-52)
        }
    }
}

private let systemTapStream = InputStreamDescriptor(
    bufferIndex: 0,
    startingChannelIndex: 0,
    channelCount: 2,
    terminalType: .unknown,
    name: "NoteTaker Tap"
)

private let refreshedSystemTapStream = InputStreamDescriptor(
    bufferIndex: 0,
    startingChannelIndex: 0,
    channelCount: 2,
    terminalType: .unknown,
    name: "Refreshed Tap"
)

private let systemTapStreamForMixedAggregate = InputStreamDescriptor(
    bufferIndex: 1,
    startingChannelIndex: 1,
    channelCount: 2,
    terminalType: .unknown,
    name: "NoteTaker Tap"
)

private final class AggregateRegistryDouble: CoreAudioPropertyReading, @unchecked Sendable {
    var sampleRates: [AudioObjectID: Float64]
    var streamReads: [AudioObjectID: [InputStreamDescriptor]]
    var inputBufferChannelCounts: [AudioObjectID: [Int]]
    var uids: [AudioObjectID: String]
    var defaultOutputID: AudioObjectID
    var streamReadIDs: [AudioObjectID] = []
    var uidReadIDs: [AudioObjectID] = []
    var defaultOutputReads = 0
    private var descriptorsByStreamID: [AudioObjectID: InputStreamDescriptor] = [:]

    var registry: AudioDeviceRegistry { AudioDeviceRegistry(reader: self) }

    init(
        sampleRates: [AudioObjectID: Float64],
        streamReads: [AudioObjectID: [InputStreamDescriptor]],
        inputBufferChannelCounts: [AudioObjectID: [Int]]? = nil,
        uids: [AudioObjectID: String],
        defaultOutputID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    ) {
        self.sampleRates = sampleRates
        self.streamReads = streamReads
        self.inputBufferChannelCounts = inputBufferChannelCounts ?? streamReads.mapValues { streams in
            streams.map(\.channelCount)
        }
        self.uids = uids
        self.defaultOutputID = defaultOutputID
    }

    func getUInt32(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> UInt32 {
        if objectID == AudioObjectID(kAudioObjectSystemObject),
           address.mSelector == kAudioHardwarePropertyDefaultOutputDevice {
            defaultOutputReads += 1
            return defaultOutputID
        }
        if let descriptor = descriptorsByStreamID[objectID] {
            switch address.mSelector {
            case kAudioStreamPropertyStartingChannel:
                return UInt32(descriptor.startingChannelIndex + 1)
            case kAudioStreamPropertyTerminalType:
                switch descriptor.terminalType {
                case .microphone:
                    return kAudioStreamTerminalTypeMicrophone
                case .headset:
                    return kAudioStreamTerminalTypeHeadsetMicrophone
                case .line:
                    return kAudioStreamTerminalTypeLine
                case .unknown:
                    return 0
                }
            default:
                break
            }
        }
        throw missingValue(objectID: objectID, address: address)
    }

    func getFloat64(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> Float64 {
        guard address.mSelector == kAudioDevicePropertyNominalSampleRate,
              let sampleRate = sampleRates[objectID] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return sampleRate
    }

    func getAudioStreamBasicDescription(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription {
        if address.mSelector == kAudioStreamPropertyVirtualFormat,
           let descriptor = descriptorsByStreamID[objectID] {
            return AudioStreamBasicDescription(
                mSampleRate: 44_100,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(descriptor.channelCount * 4),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(descriptor.channelCount * 4),
                mChannelsPerFrame: UInt32(descriptor.channelCount),
                mBitsPerChannel: 32,
                mReserved: 0
            )
        }
        throw missingValue(objectID: objectID, address: address)
    }

    func getAudioObjectIDs(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        guard address.mSelector == kAudioDevicePropertyStreams,
              let streams = streamReads[objectID] else {
            throw missingValue(objectID: objectID, address: address)
        }
        streamReadIDs.append(objectID)
        descriptorsByStreamID = Dictionary(uniqueKeysWithValues: streams.enumerated().map { index, descriptor in
            (AudioObjectID(1_000 + index), descriptor)
        })
        return streams.enumerated().map { index, _ in AudioObjectID(1_000 + index) }
    }

    func getString(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
        if address.mSelector == kAudioDevicePropertyDeviceUID, let uid = uids[objectID] {
            uidReadIDs.append(objectID)
            return uid
        }
        if address.mSelector == kAudioObjectPropertyName,
           let descriptor = descriptorsByStreamID[objectID] {
            return descriptor.name
        }
        throw missingValue(objectID: objectID, address: address)
    }

    func inputBufferChannelCounts(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> [Int] {
        guard address.mSelector == kAudioDevicePropertyStreamConfiguration,
              address.mScope == kAudioObjectPropertyScopeInput,
              let channelCounts = inputBufferChannelCounts[objectID] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return channelCounts
    }

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        AudioObjectID(kAudioObjectUnknown)
    }

    private func missingValue(objectID: AudioObjectID, address: AudioObjectPropertyAddress) -> CoreAudioError {
        CoreAudioError(status: kAudioHardwareUnknownPropertyError, operation: .getData, objectID: objectID, selector: address.mSelector)
    }
}

private func expectHALSubDevices(_ properties: [String: Any], equal expected: [[String: AnyHashable]]) {
    let subDevices = properties[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
    #expect(subDevices?.count == expected.count)
    for (actual, expected) in zip(subDevices ?? [], expected) {
        #expect(actual[kAudioSubDeviceUIDKey] as? String == expected["uid"] as? String)
        #expect(actual[kAudioSubDeviceDriftCompensationKey] as? Bool == expected["drift"] as? Bool)
    }
}

private func expectHALTaps(_ properties: [String: Any], equal expected: [[String: AnyHashable]]) {
    let taps = properties[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
    #expect(taps?.count == expected.count)
    for (actual, expected) in zip(taps ?? [], expected) {
        #expect(actual[kAudioSubTapUIDKey] as? String == expected["uid"] as? String)
        #expect(actual[kAudioSubTapDriftCompensationKey] as? Bool == expected["drift"] as? Bool)
    }
}
