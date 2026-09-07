@testable import AudioPipeline
import CoreAudio
import Foundation
import Testing

@Test("SystemAudioTapFactory builds a private stereo global tap excluding the current HAL process")
func systemAudioTapFactoryBuildsPrivateStereoGlobalTapExcludingCurrentProcess() throws {
    let expectedUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let api = FakeCoreAudioProcessTapAPI(createdID: 88)
    let factory = SystemAudioTapFactory(api: api, makeUUID: { expectedUUID })

    let tap = try factory.create(excludingProcessID: 41)

    let description = try #require(api.createdDescriptions.first)
    #expect(description.processes == [AudioObjectID(41)])
    #expect(description.isExclusive)
    #expect(description.isMixdown)
    #expect(!description.isMono)
    #expect(description.isPrivate)
    #expect(description.muteBehavior == .unmuted)
    #expect(description.uuid == expectedUUID)
    #expect(tap.id == 88)
    #expect(tap.uid == expectedUUID)
    #expect(tap.warnings == [])
}

@Test("SystemAudioTapFactory warns once and excludes nothing when self process object is unavailable")
func systemAudioTapFactoryWarnsWhenSelfProcessObjectUnavailable() throws {
    let expectedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let api = FakeCoreAudioProcessTapAPI(createdID: 89)
    let factory = SystemAudioTapFactory(api: api, makeUUID: { expectedUUID })

    let tap = try factory.create(excludingProcessID: nil)

    let description = try #require(api.createdDescriptions.first)
    #expect(description.processes == [])
    #expect(description.isExclusive)
    #expect(description.isMixdown)
    #expect(!description.isMono)
    #expect(description.isPrivate)
    #expect(description.muteBehavior == .unmuted)
    #expect(description.uuid == expectedUUID)
    #expect(tap.warnings == [.selfExclusionUnavailable])
}

@Test("SystemAudioTapFactory maps only create permission errors to systemAudioPermissionDenied")
func systemAudioTapFactoryMapsPermissionDeniedCreateStatus() {
    let api = SystemCoreAudioProcessTapAPI(
        createProcessTap: { _, _ in kAudioDevicePermissionsError },
        destroyProcessTap: { _ in kAudioHardwareNoError }
    )

    #expect(throws: AudioCaptureError.systemAudioPermissionDenied) {
        _ = try api.createProcessTap(description: CATapDescription(stereoGlobalTapButExcludeProcesses: []))
    }
}

@Test("SystemAudioTapFactory maps other create failures to tapCreationFailed")
func systemAudioTapFactoryMapsOtherCreateStatus() {
    let api = SystemCoreAudioProcessTapAPI(
        createProcessTap: { _, _ in OSStatus(-12_345) },
        destroyProcessTap: { _ in kAudioHardwareNoError }
    )

    #expect(throws: AudioCaptureError.tapCreationFailed(-12_345)) {
        _ = try api.createProcessTap(description: CATapDescription(stereoGlobalTapButExcludeProcesses: []))
    }
}

@Test("SystemCoreAudioProcessTapAPI rejects successful creates that return an unknown tap object")
func systemCoreAudioProcessTapAPIRejectsUnknownTapObjectAfterSuccessfulCreate() {
    let api = SystemCoreAudioProcessTapAPI(
        createProcessTap: { _, _ in kAudioHardwareNoError },
        destroyProcessTap: { _ in kAudioHardwareNoError }
    )

    #expect(throws: AudioCaptureError.tapCreationFailed(kAudioHardwareBadObjectError)) {
        _ = try api.createProcessTap(description: CATapDescription(stereoGlobalTapButExcludeProcesses: []))
    }
}

@Test("SystemCoreAudioProcessTapAPI returns raw tap object from successful create")
func systemCoreAudioProcessTapAPIReturnsRawTapObjectFromSuccessfulCreate() throws {
    let api = SystemCoreAudioProcessTapAPI(
        createProcessTap: { _, outTapID in
            outTapID.pointee = 123
            return kAudioHardwareNoError
        },
        destroyProcessTap: { _ in kAudioHardwareNoError }
    )

    #expect(try api.createProcessTap(description: CATapDescription(stereoGlobalTapButExcludeProcesses: [])) == 123)
}

@Test("SystemCoreAudioProcessTapAPI maps raw destroy failures to destroyTap")
func systemCoreAudioProcessTapAPIMapsRawDestroyFailuresToDestroyTap() {
    let api = SystemCoreAudioProcessTapAPI(
        createProcessTap: { _, _ in kAudioHardwareNoError },
        destroyProcessTap: { objectID in
            #expect(objectID == 124)
            return OSStatus(-98)
        }
    )

    #expect(throws: CoreAudioError(status: -98, operation: .destroyTap, objectID: 124, selector: nil)) {
        try api.destroyProcessTap(124)
    }
}

@Test(
    "SystemAudioTap currentFormat accepts valid Float32 stereo layouts",
    arguments: [
        validASBD(sampleRate: 44_100, flags: packedNativeFloatFlags, bytes: 8),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags, bytes: 8),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags | kAudioFormatFlagIsNonInterleaved, bytes: 4)
    ]
)
func systemAudioTapCurrentFormatAcceptsValidFloat32StereoLayouts(asbd: AudioStreamBasicDescription) throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 90)
    api.formats = [asbd]
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    let format = try tap.currentFormat()

    #expect(format == SystemAudioTapFormat(asbd))
    #expect(api.formatReads.map(\.objectID) == [90])
    #expect(api.formatReads.map(\.selector) == [kAudioTapPropertyFormat])
}

@Test(
    "SystemAudioTap currentFormat rejects unsupported stream formats while leaving the owner destroyable",
    arguments: invalidASBDs()
)
func systemAudioTapCurrentFormatRejectsUnsupportedFormats(asbd: AudioStreamBasicDescription) throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 91)
    api.formats = [asbd]
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    #expect(throws: AudioCaptureError.unsupportedStreamFormat(nil)) {
        _ = try tap.currentFormat()
    }

    try tap.destroy()
    #expect(api.destroyCalls == [91])
}

@Test("SystemAudioTap currentFormat propagates exact Core Audio read errors")
func systemAudioTapCurrentFormatPropagatesReadErrors() throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 92)
    let expectedError = CoreAudioError(
        status: -55,
        operation: .getData,
        objectID: 92,
        selector: kAudioTapPropertyFormat
    )
    api.formatErrors = [expectedError]
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    #expect(throws: expectedError) {
        _ = try tap.currentFormat()
    }

    try tap.destroy()
    #expect(api.destroyCalls == [92])
}

@Test("SystemAudioTap currentFormat performs a fresh format read each call")
func systemAudioTapCurrentFormatPerformsFreshReadEachCall() throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 93)
    api.formats = [
        validASBD(sampleRate: 44_100, flags: packedNativeFloatFlags, bytes: 8),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags, bytes: 8)
    ]
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    #expect(try tap.currentFormat().sampleRate == 44_100)
    #expect(try tap.currentFormat().sampleRate == 48_000)
    #expect(api.formatReads.map(\.objectID) == [93, 93])
}

@Test("SystemAudioTap destroy serializes repeated calls into one successful HAL destroy")
func systemAudioTapDestroySerializesRepeatedCalls() throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 94)
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    try tap.destroy()
    try tap.destroy()

    #expect(api.destroyCalls == [94])
}

@Test("SystemAudioTap destroy serializes concurrent callers into one successful HAL destroy")
func systemAudioTapDestroySerializesConcurrentCallers() throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 96)
    api.destroyDelay = 0.05
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)
    let queue = DispatchQueue(label: "SystemAudioTapTests.destroy", attributes: .concurrent)
    let group = DispatchGroup()
    let errorRecorder = ErrorRecorder()

    for _ in 0..<2 {
        group.enter()
        queue.async {
            do {
                try tap.destroy()
            } catch {
                errorRecorder.append(error)
            }
            group.leave()
        }
    }

    #expect(group.wait(timeout: .now() + 2) == .success)
    #expect(errorRecorder.errors.isEmpty)
    #expect(api.destroyCalls == [96])
}

@Test("SystemAudioTap destroy remains retryable after a Core Audio failure")
func systemAudioTapDestroyRetriesAfterFailure() throws {
    let api = FakeCoreAudioProcessTapAPI(createdID: 95)
    let expectedError = CoreAudioError(status: -77, operation: .destroyTap, objectID: 95, selector: nil)
    api.destroyErrors = [expectedError]
    let tap = try SystemAudioTapFactory(api: api, makeUUID: { UUID() }).create(excludingProcessID: 41)

    #expect(throws: expectedError) {
        try tap.destroy()
    }

    try tap.destroy()
    #expect(api.destroyCalls == [95, 95])
}

private let packedNativeFloatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian

private func validASBD(
    sampleRate: Double,
    flags: AudioFormatFlags,
    bytes: UInt32
) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytes,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytes,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func invalidASBDs() -> [AudioStreamBasicDescription] {
    [
        validASBD(sampleRate: 48_000, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, bytes: 8),
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: packedNativeFloatFlags,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        ),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags, bytes: 8).with(bitsPerChannel: 16),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags | kAudioFormatFlagIsBigEndian, bytes: 8),
        validASBD(sampleRate: 0, flags: packedNativeFloatFlags, bytes: 8),
        validASBD(sampleRate: .nan, flags: packedNativeFloatFlags, bytes: 8),
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        ),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags, bytes: 4),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags | kAudioFormatFlagIsNonInterleaved, bytes: 8),
        validASBD(sampleRate: 48_000, flags: packedNativeFloatFlags, bytes: 8).with(framesPerPacket: 2)
    ]
}

private extension AudioStreamBasicDescription {
    func with(
        bitsPerChannel: UInt32? = nil,
        framesPerPacket: UInt32? = nil
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: mSampleRate,
            mFormatID: mFormatID,
            mFormatFlags: mFormatFlags,
            mBytesPerPacket: mBytesPerPacket,
            mFramesPerPacket: framesPerPacket ?? mFramesPerPacket,
            mBytesPerFrame: mBytesPerFrame,
            mChannelsPerFrame: mChannelsPerFrame,
            mBitsPerChannel: bitsPerChannel ?? mBitsPerChannel,
            mReserved: mReserved
        )
    }
}

private extension SystemAudioTapFormat {
    init(_ asbd: AudioStreamBasicDescription) {
        self.init(
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

private final class FakeCoreAudioProcessTapAPI: CoreAudioProcessTapAPI, @unchecked Sendable {
    struct FormatRead: Equatable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    private let lock = NSLock()
    private let createdID: AudioObjectID
    private let createError: Error?
    var formats: [AudioStreamBasicDescription] = []
    var formatErrors: [Error] = []
    var destroyErrors: [Error] = []
    var destroyDelay: TimeInterval = 0
    private(set) var createdDescriptions: [CATapDescription] = []
    private(set) var formatReads: [FormatRead] = []
    private(set) var destroyCalls: [AudioObjectID] = []

    init(createdID: AudioObjectID = 100, createError: Error? = nil) {
        self.createdID = createdID
        self.createError = createError
    }

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        lock.lock()
        createdDescriptions.append(description)
        let error = createError
        lock.unlock()
        if let error {
            throw error
        }
        return createdID
    }

    func readTapFormat(objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        lock.lock()
        formatReads.append(FormatRead(objectID: objectID, selector: kAudioTapPropertyFormat))
        let error = formatErrors.isEmpty ? nil : formatErrors.removeFirst()
        let format = formats.isEmpty ? nil : formats.removeFirst()
        lock.unlock()
        if let error {
            throw error
        }
        return try #require(format)
    }

    func destroyProcessTap(_ objectID: AudioObjectID) throws {
        lock.lock()
        destroyCalls.append(objectID)
        let error = destroyErrors.isEmpty ? nil : destroyErrors.removeFirst()
        let delay = destroyDelay
        lock.unlock()
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if let error {
            throw error
        }
    }
}

private final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [any Error] = []

    func append(_ error: any Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
