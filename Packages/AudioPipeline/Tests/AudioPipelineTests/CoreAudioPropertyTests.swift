@testable import AudioPipeline
import CoreAudio
import Testing

@Test("Core Audio property address uses global main defaults and keeps explicit input scope")
func coreAudioPropertyAddressUsesExpectedDefaultsAndInputScope() {
    let defaultAddress = CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
    #expect(defaultAddress.mSelector == kAudioHardwarePropertyDefaultInputDevice)
    #expect(defaultAddress.mScope == kAudioObjectPropertyScopeGlobal)
    #expect(defaultAddress.mElement == kAudioObjectPropertyElementMain)

    let inputAddress = CoreAudioProperty.address(
        kAudioDevicePropertyStreamConfiguration,
        scope: kAudioObjectPropertyScopeInput
    )
    #expect(inputAddress.mSelector == kAudioDevicePropertyStreamConfiguration)
    #expect(inputAddress.mScope == kAudioObjectPropertyScopeInput)
    #expect(inputAddress.mElement == kAudioObjectPropertyElementMain)
}

@Test("Core Audio errors retain status operation object and selector")
func coreAudioErrorsRetainStatusOperationObjectAndSelector() {
    let error = CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getData,
        objectID: AudioObjectID(42),
        selector: kAudioDevicePropertyDeviceUID
    )

    #expect(error.status == kAudioHardwareBadPropertySizeError)
    #expect(error.operation == .getData)
    #expect(error.objectID == 42)
    #expect(error.selector == kAudioDevicePropertyDeviceUID)
}

@Test("Core Audio size validation rejects scalar zero and mismatched byte counts")
func coreAudioSizeValidationRejectsScalarZeroAndMismatchedByteCounts() {
    let address = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getDataSize,
        objectID: 7,
        selector: kAudioDevicePropertyNominalSampleRate
    )) {
        try CoreAudioProperty.validateScalarSize(0, objectID: 7, address: address, as: Float64.self)
    }

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getDataSize,
        objectID: 7,
        selector: kAudioDevicePropertyNominalSampleRate
    )) {
        try CoreAudioProperty.validateScalarSize(4, objectID: 7, address: address, as: Float64.self)
    }
}

@Test("Core Audio size validation rejects zero arrays and indivisible byte counts")
func coreAudioSizeValidationRejectsZeroArraysAndIndivisibleByteCounts() {
    let address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
    let systemObject = AudioObjectID(kAudioObjectSystemObject)

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getDataSize,
        objectID: systemObject,
        selector: kAudioHardwarePropertyDevices
    )) {
        _ = try CoreAudioProperty.arrayCount(
            byteSize: 0,
            objectID: systemObject,
            address: address,
            as: AudioObjectID.self
        )
    }

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getDataSize,
        objectID: systemObject,
        selector: kAudioHardwarePropertyDevices
    )) {
        _ = try CoreAudioProperty.arrayCount(
            byteSize: 6,
            objectID: systemObject,
            address: address,
            as: AudioObjectID.self
        )
    }
}

@Test("Core Audio array count after read trims elements not written by HAL")
func coreAudioArrayCountAfterReadTrimsElementsNotWrittenByHAL() throws {
    let address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
    let elementStride = UInt32(MemoryLayout<UInt32>.stride)

    let actualCount = try CoreAudioProperty.arrayCountAfterRead(
        allocatedByteSize: 4 * elementStride,
        returnedByteSize: 2 * elementStride,
        objectID: AudioObjectID(kAudioObjectSystemObject),
        address: address,
        as: UInt32.self
    )

    #expect(actualCount == 2)
}

@Test("Core Audio array count after read rejects bytes beyond allocation")
func coreAudioArrayCountAfterReadRejectsBytesBeyondAllocation() {
    let address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
    let elementStride = UInt32(MemoryLayout<UInt32>.stride)

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getData,
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDevices
    )) {
        _ = try CoreAudioProperty.arrayCountAfterRead(
            allocatedByteSize: 2 * elementStride,
            returnedByteSize: 3 * elementStride,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            as: UInt32.self
        )
    }
}

@Test("Core Audio terminal constants map to microphone headset line and unknown")
func coreAudioTerminalConstantsMapToInternalTerminalTypes() {
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeMicrophone) == .microphone)
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeReceiverMicrophone) == .microphone)
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeHeadsetMicrophone) == .headset)
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeLine) == .line)
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeUnknown) == .unknown)
    #expect(InputTerminalType(coreAudioTerminalType: kAudioStreamTerminalTypeSpeaker) == .unknown)
}

@Test("Core Audio buffer list byte count includes the variable tail buffers")
func coreAudioBufferListByteCountIncludesVariableTailBuffers() {
    let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let bufferStride = MemoryLayout<AudioBuffer>.stride

    #expect(CoreAudioProperty.audioBufferListByteSize(bufferCount: 0) == headerSize)
    #expect(CoreAudioProperty.audioBufferListByteSize(bufferCount: 1) == headerSize + bufferStride)
    #expect(
        CoreAudioProperty.audioBufferListByteSize(bufferCount: 3)
            == headerSize + (3 * bufferStride)
    )
}

@Test("Core Audio buffer list parser accepts zero one and three buffers")
func coreAudioBufferListParserAcceptsZeroOneAndThreeBuffers() throws {
    #expect(try parseInputBufferChannelCounts([]) == [])
    #expect(try parseInputBufferChannelCounts([2]) == [2])
    #expect(try parseInputBufferChannelCounts([1, 2, 4]) == [1, 2, 4])
}

@Test("Core Audio buffer list parser rejects impossible reported buffer counts")
func coreAudioBufferListParserRejectsImpossibleReportedBufferCounts() {
    let address = CoreAudioProperty.address(
        kAudioDevicePropertyStreamConfiguration,
        scope: kAudioObjectPropertyScopeInput
    )
    let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride

    #expect(throws: CoreAudioError(
        status: kAudioHardwareBadPropertySizeError,
        operation: .getData,
        objectID: 99,
        selector: kAudioDevicePropertyStreamConfiguration
    )) {
        try withAudioBufferListStorage(channelCounts: [], reportedBufferCount: 3) { storage, _ in
            _ = try CoreAudioProperty.parseInputBufferChannelCounts(
                from: storage,
                returnedByteCount: UInt32(headerSize),
                allocatedByteCount: UInt32(headerSize),
                objectID: 99,
                address: address
            )
        }
    }
}

private func parseInputBufferChannelCounts(_ channelCounts: [UInt32]) throws -> [Int] {
    let address = CoreAudioProperty.address(
        kAudioDevicePropertyStreamConfiguration,
        scope: kAudioObjectPropertyScopeInput
    )
    return try withAudioBufferListStorage(channelCounts: channelCounts) { storage, byteCount in
        try CoreAudioProperty.parseInputBufferChannelCounts(
            from: storage,
            returnedByteCount: UInt32(byteCount),
            allocatedByteCount: UInt32(byteCount),
            objectID: 99,
            address: address
        )
    }
}

private func withAudioBufferListStorage<Result>(
    channelCounts: [UInt32],
    reportedBufferCount: UInt32? = nil,
    _ body: (UnsafeMutableRawPointer, Int) throws -> Result
) rethrows -> Result {
    let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let bufferStride = MemoryLayout<AudioBuffer>.stride
    let byteCount = headerSize + (channelCounts.count * bufferStride)
    let allocationByteCount = max(byteCount, MemoryLayout<UInt32>.size)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: allocationByteCount,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: allocationByteCount)
    storage.storeBytes(of: reportedBufferCount ?? UInt32(channelCounts.count), as: UInt32.self)
    for (index, channelCount) in channelCounts.enumerated() {
        let buffer = AudioBuffer(mNumberChannels: channelCount, mDataByteSize: 0, mData: nil)
        storage
            .advanced(by: headerSize + (index * bufferStride))
            .storeBytes(of: buffer, as: AudioBuffer.self)
    }
    return try body(storage, byteCount)
}
