@testable import AudioPipeline
import CoreAudio
import Testing

@Test("AudioProcessObjects.processObjectID primes HAL before translating the requested PID")
func audioProcessObjectsProcessObjectIDPrimesHALBeforeTranslatingRequestedPID() throws {
    let query = FakeAudioProcessObjectQuery(translations: [321: 44])
    let objects = AudioProcessObjects(query: query)

    #expect(try objects.processObjectID(for: 321) == 44)
    #expect(query.events == [.primeHALClient, .translatePID(321)])
}

@Test("AudioProcessObjects.processObjectID maps only unknown process objects to nil")
func audioProcessObjectsProcessObjectIDMapsOnlyUnknownProcessObjectsToNil() throws {
    let query = FakeAudioProcessObjectQuery(translations: [321: AudioObjectID(kAudioObjectUnknown)])
    let unknownObjects = AudioProcessObjects(query: query)

    #expect(try unknownObjects.processObjectID(for: 321) == nil)
    #expect(query.events == [.primeHALClient, .translatePID(321)])
}

@Test("SystemAudioProcessObjectQuery.translatePID uses the qualified PID translation contract")
func systemAudioProcessObjectQueryTranslatePIDUsesQualifiedPIDTranslationContract() throws {
    let getter = FakeAudioObjectPropertyDataGetter()
    getter.results = [
        .success(output: 44, returnedByteCount: UInt32(MemoryLayout<AudioObjectID>.size))
    ]
    let query = SystemAudioProcessObjectQuery(getPropertyData: getter.getPropertyData)

    #expect(try query.translatePID(321) == 44)

    let call = try #require(getter.calls.first)
    #expect(call.objectID == AudioObjectID(kAudioObjectSystemObject))
    #expect(call.address.mSelector == kAudioHardwarePropertyTranslatePIDToProcessObject)
    #expect(call.address.mScope == kAudioObjectPropertyScopeGlobal)
    #expect(call.address.mElement == kAudioObjectPropertyElementMain)
    #expect(call.qualifierByteCount == UInt32(MemoryLayout<pid_t>.size))
    #expect(call.qualifierPID == pid_t(321))
    #expect(call.requestedOutputByteCount == UInt32(MemoryLayout<AudioObjectID>.size))
}

@Test("SystemAudioProcessObjectQuery.translatePID propagates unchanged Core Audio failures")
func systemAudioProcessObjectQueryTranslatePIDPropagatesUnchangedCoreAudioFailures() {
    let getter = FakeAudioObjectPropertyDataGetter()
    getter.results = [
        .failure(status: OSStatus(-12_345))
    ]
    let query = SystemAudioProcessObjectQuery(getPropertyData: getter.getPropertyData)

    #expect(throws: CoreAudioError(
        status: OSStatus(-12_345),
        operation: .getData,
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyTranslatePIDToProcessObject
    )) {
        _ = try query.translatePID(321)
    }
}

@Test("SystemAudioProcessObjectQuery.translatePID rejects returned scalar sizes that are not AudioObjectID sized")
func systemAudioProcessObjectQueryTranslatePIDRejectsInvalidReturnedScalarSize() {
    let getter = FakeAudioObjectPropertyDataGetter()
    getter.results = [
        .success(
            output: 44,
            returnedByteCount: UInt32(MemoryLayout<AudioObjectID>.size - 1)
        )
    ]
    let query = SystemAudioProcessObjectQuery(getPropertyData: getter.getPropertyData)

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getData,
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyTranslatePIDToProcessObject
    )) {
        _ = try query.translatePID(321)
    }
}

@Test("AudioProcessObjects default output registry uses the default output selector for unknown devices")
func audioProcessObjectsDefaultOutputRegistryUsesDefaultOutputSelectorForUnknownDevices() {
    let reader = FocusedRegistryFakeReader()
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

private enum ProcessQueryEvent: Equatable {
    case primeHALClient
    case translatePID(pid_t)
}

private final class FakeAudioProcessObjectQuery: AudioProcessObjectQuerying, @unchecked Sendable {
    var events: [ProcessQueryEvent] = []
    var translations: [pid_t: AudioObjectID]

    init(translations: [pid_t: AudioObjectID]) {
        self.translations = translations
    }

    func primeHALClient() throws {
        events.append(.primeHALClient)
    }

    func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        events.append(.translatePID(pid))
        return translations[pid] ?? AudioObjectID(kAudioObjectUnknown)
    }
}

private final class FocusedRegistryFakeReader: CoreAudioPropertyReading, @unchecked Sendable {
    var uint32s: [FocusedRegistryPropertyKey: UInt32] = [:]
    var uint32Reads: [FocusedRegistryPropertyKey] = []

    func getUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        let key = FocusedRegistryPropertyKey(objectID, address)
        uint32Reads.append(key)
        guard let value = uint32s[key] else {
            throw missingValue(objectID: objectID, address: address)
        }
        return value
    }

    func getFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64 {
        throw missingValue(objectID: objectID, address: address)
    }

    func getAudioStreamBasicDescription(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription {
        throw missingValue(objectID: objectID, address: address)
    }

    func getAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        throw missingValue(objectID: objectID, address: address)
    }

    func getString(objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
        throw missingValue(objectID: objectID, address: address)
    }

    func inputBufferChannelCounts(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [Int] {
        throw missingValue(objectID: objectID, address: address)
    }

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        AudioObjectID(kAudioObjectUnknown)
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

private struct FocusedRegistryPropertyKey: Hashable {
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

private final class FakeAudioObjectPropertyDataGetter: @unchecked Sendable {
    struct Call {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let qualifierByteCount: UInt32
        let qualifierPID: pid_t?
        let requestedOutputByteCount: UInt32
    }

    enum Result {
        case success(output: AudioObjectID, returnedByteCount: UInt32)
        case failure(status: OSStatus)
    }

    var calls: [Call] = []
    var results: [Result] = []

    func getPropertyData(
        objectID: AudioObjectID,
        address: UnsafePointer<AudioObjectPropertyAddress>,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        ioDataSize: UnsafeMutablePointer<UInt32>,
        outData: UnsafeMutableRawPointer
    ) -> OSStatus {
        calls.append(Call(
            objectID: objectID,
            address: address.pointee,
            qualifierByteCount: qualifierDataSize,
            qualifierPID: qualifierData?.load(as: pid_t.self),
            requestedOutputByteCount: ioDataSize.pointee
        ))

        guard !results.isEmpty else { return kAudioHardwareUnknownPropertyError }
        switch results.removeFirst() {
        case let .success(output, returnedByteCount):
            outData.storeBytes(of: output, as: AudioObjectID.self)
            ioDataSize.pointee = returnedByteCount
            return kAudioHardwareNoError
        case let .failure(status):
            return status
        }
    }
}
