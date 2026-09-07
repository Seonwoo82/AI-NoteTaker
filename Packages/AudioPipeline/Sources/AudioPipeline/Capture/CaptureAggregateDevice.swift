import CoreAudio
import Foundation

protocol CaptureAggregateDeviceDestroying: AnyObject, Sendable {
    func destroy() throws
}

protocol CaptureAggregateDeviceManaging: CaptureAggregateDeviceDestroying {
    var id: AudioObjectID { get }
    var uid: String { get }
    var sampleRate: Double { get }
    var inputStreams: [InputStreamDescriptor] { get }
    var channelMap: InputChannelMap { get }
    var inputChannelCount: Int { get }
    var inputBufferChannelCounts: [Int] { get }
    var bufferFrameSize: Int { get }

    func currentInputStreams() throws -> [InputStreamDescriptor]
    func currentInputBufferChannelCounts() throws -> [Int]
}

final class CaptureAggregateCreationCleanupError: Error, @unchecked Sendable {
    let originalError: Error
    let cleanupError: Error
    let pendingOwner: any CaptureAggregateDeviceDestroying

    init(
        originalError: Error,
        cleanupError: Error,
        pendingOwner: any CaptureAggregateDeviceDestroying
    ) {
        self.originalError = originalError
        self.cleanupError = cleanupError
        self.pendingOwner = pendingOwner
    }
}

protocol CaptureAggregateDeviceMaking: Sendable {
    func createMicOnlyAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor]
    ) throws -> any CaptureAggregateDeviceManaging
    func createSystemOnlyAggregate(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int
    ) throws -> any CaptureAggregateDeviceManaging
    func createMicAndSystemAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) throws -> any CaptureAggregateDeviceManaging
}

protocol CoreAudioAggregateDeviceAPI: Sendable {
    func createAggregateDevice(properties: [String: Any]) throws -> AudioObjectID
    func destroyAggregateDevice(_ id: AudioObjectID) throws
}

struct SystemCoreAudioAggregateDeviceAPI: CoreAudioAggregateDeviceAPI {
    func createAggregateDevice(properties: [String: Any]) throws -> AudioObjectID {
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregateID)
        guard status == kAudioHardwareNoError else {
            throw AudioCaptureError.aggregateCreationFailed(status)
        }
        return aggregateID
    }

    func destroyAggregateDevice(_ id: AudioObjectID) throws {
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == kAudioHardwareNoError else {
            throw CoreAudioError(
                status: status,
                operation: .destroyAggregate,
                objectID: id,
                selector: nil
            )
        }
    }
}

public final class CaptureAggregateDevice: CaptureAggregateDeviceManaging, @unchecked Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let sampleRate: Double
    public let inputStreams: [InputStreamDescriptor]
    public let channelMap: InputChannelMap
    public let inputChannelCount: Int
    public let inputBufferChannelCounts: [Int]
    public let bufferFrameSize: Int

    private let api: any CoreAudioAggregateDeviceAPI
    private let readInputStreams: @Sendable () throws -> [InputStreamDescriptor]
    private let readInputBufferChannelCounts: @Sendable () throws -> [Int]
    private let lock = NSLock()
    private var destroyed = false

    typealias BufferFrameSizeReader = @Sendable (_ aggregateID: AudioObjectID) throws -> Int

    static func createMicOnly(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        registry: AudioDeviceRegistry = AudioDeviceRegistry(),
        api: any CoreAudioAggregateDeviceAPI = SystemCoreAudioAggregateDeviceAPI(),
        readBufferFrameSize: BufferFrameSizeReader = CaptureAggregateDevice.readBufferFrameSize(for:)
    ) throws -> CaptureAggregateDevice {
        let uid = "com.seonwoo.notetaker.aggregate.mic.\(UUID().uuidString)"
        let composition = try AggregateComposition(
            mode: .micOnly,
            microphoneUID: microphoneUID,
            outputUID: nil,
            tapUID: nil
        )
        return try create(
            composition: composition,
            name: "NoteTaker Microphone Aggregate",
            uid: uid,
            microphoneStreams: microphoneStreams,
            tapChannelCount: 0,
            registry: registry,
            api: api,
            readBufferFrameSize: readBufferFrameSize
        )
    }

    static func createSystemOnly(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        registry: AudioDeviceRegistry = AudioDeviceRegistry(),
        api: any CoreAudioAggregateDeviceAPI = SystemCoreAudioAggregateDeviceAPI(),
        readBufferFrameSize: BufferFrameSizeReader = CaptureAggregateDevice.readBufferFrameSize(for:)
    ) throws -> CaptureAggregateDevice {
        let uid = "com.seonwoo.notetaker.aggregate.system.\(UUID().uuidString)"
        let composition = try AggregateComposition(
            mode: .systemOnly,
            microphoneUID: nil,
            outputUID: outputUID,
            tapUID: tapUID
        )
        return try create(
            composition: composition,
            name: "NoteTaker System Audio Aggregate",
            uid: uid,
            microphoneStreams: [],
            tapChannelCount: tapChannelCount,
            registry: registry,
            api: api,
            readBufferFrameSize: readBufferFrameSize
        )
    }

    static func createMicAndSystem(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource = .microphone,
        registry: AudioDeviceRegistry = AudioDeviceRegistry(),
        api: any CoreAudioAggregateDeviceAPI = SystemCoreAudioAggregateDeviceAPI(),
        readBufferFrameSize: BufferFrameSizeReader = CaptureAggregateDevice.readBufferFrameSize(for:)
    ) throws -> CaptureAggregateDevice {
        let uid = "com.seonwoo.notetaker.aggregate.mixed.\(UUID().uuidString)"
        let composition = try AggregateComposition(
            mode: .micAndSystem,
            microphoneUID: microphoneUID,
            outputUID: outputUID,
            tapUID: tapUID,
            clockSource: clockSource
        )
        return try create(
            composition: composition,
            name: "NoteTaker Mic and System Aggregate",
            uid: uid,
            microphoneStreams: microphoneStreams,
            tapChannelCount: tapChannelCount,
            registry: registry,
            api: api,
            readBufferFrameSize: readBufferFrameSize
        )
    }

    private static func create(
        composition: AggregateComposition,
        name: String,
        uid: String,
        microphoneStreams: [InputStreamDescriptor],
        tapChannelCount: Int,
        registry: AudioDeviceRegistry,
        api: any CoreAudioAggregateDeviceAPI,
        readBufferFrameSize: BufferFrameSizeReader
    ) throws -> CaptureAggregateDevice {
        let aggregateID = try api.createAggregateDevice(
            properties: composition.makeHALProperties(name: name, uid: uid)
        )
        let newAggregate = CreatedAggregateOwnership(id: aggregateID, api: api)

        do {
            let sampleRate = try registry.nominalSampleRate(for: aggregateID)
            let aggregateStreams = try packedInputStreams(registry.inputStreamDescriptors(for: aggregateID))
            let inputBufferChannelCounts = try registry.inputBufferChannelCounts(for: aggregateID)
            let channelMap = try ChannelMapResolver.resolve(
                aggregateStreams: aggregateStreams,
                inputBufferChannelCounts: inputBufferChannelCounts,
                microphoneStreams: microphoneStreams,
                tapChannelCount: tapChannelCount
            )
            let inputChannelCount = try totalInputChannelCount(for: aggregateStreams)
            let bufferFrameSize = try readBufferFrameSize(aggregateID)
            let aggregate = CaptureAggregateDevice(
                id: aggregateID,
                uid: uid,
                sampleRate: sampleRate,
                inputStreams: aggregateStreams,
                channelMap: channelMap,
                inputChannelCount: inputChannelCount,
                inputBufferChannelCounts: inputBufferChannelCounts,
                bufferFrameSize: bufferFrameSize,
                api: api,
                readInputStreams: { try packedInputStreams(registry.inputStreamDescriptors(for: aggregateID)) },
                readInputBufferChannelCounts: { try registry.inputBufferChannelCounts(for: aggregateID) }
            )
            newAggregate.transferOwnership()
            return aggregate
        } catch {
            let originalError = error
            do {
                try newAggregate.destroy()
            } catch {
                throw CaptureAggregateCreationCleanupError(
                    originalError: originalError,
                    cleanupError: error,
                    pendingOwner: newAggregate
                )
            }
            throw originalError
        }
    }

    /// HAL stream addresses may include gaps occupied by non-input channels (e.g.
    /// Studio Display mic at 1, tap at 5). Our ring packs the input ABL in stream
    /// order, so use cumulative input offsets here, never in the physical registry.
    /// The resolver independently checks the StreamConfiguration channel total.
    private static func packedInputStreams(_ streams: [InputStreamDescriptor]) throws -> [InputStreamDescriptor] {
        var inputOffset = 0
        var previousHALEnd = 0
        return try streams.enumerated().map { index, stream in
            guard stream.bufferIndex == index, stream.channelCount > 0,
                  stream.startingChannelIndex >= previousHALEnd else {
                throw ChannelMapError.nonContiguousChannels
            }
            let result = InputStreamDescriptor(
                bufferIndex: index, startingChannelIndex: inputOffset,
                channelCount: stream.channelCount, terminalType: stream.terminalType, name: stream.name)
            previousHALEnd = stream.startingChannelIndex + stream.channelCount
            inputOffset += stream.channelCount
            return result
        }
    }

    init(
        id: AudioObjectID,
        uid: String,
        sampleRate: Double,
        inputStreams: [InputStreamDescriptor],
        channelMap: InputChannelMap,
        inputChannelCount: Int,
        inputBufferChannelCounts: [Int]? = nil,
        bufferFrameSize: Int,
        api: any CoreAudioAggregateDeviceAPI,
        readInputStreams: (@Sendable () throws -> [InputStreamDescriptor])? = nil,
        readInputBufferChannelCounts: (@Sendable () throws -> [Int])? = nil
    ) {
        self.id = id
        self.uid = uid
        self.sampleRate = sampleRate
        self.inputStreams = inputStreams
        self.channelMap = channelMap
        self.inputChannelCount = inputChannelCount
        let resolvedBufferChannelCounts = inputBufferChannelCounts ?? channelMap.bufferLayout.map(\.channelCount)
        self.inputBufferChannelCounts = resolvedBufferChannelCounts
        self.bufferFrameSize = bufferFrameSize
        self.api = api
        self.readInputStreams = readInputStreams ?? { inputStreams }
        self.readInputBufferChannelCounts = readInputBufferChannelCounts ?? { resolvedBufferChannelCounts }
    }

    public func currentInputStreams() throws -> [InputStreamDescriptor] {
        try readInputStreams()
    }

    public func currentInputBufferChannelCounts() throws -> [Int] {
        try readInputBufferChannelCounts()
    }

    public func destroy() throws {
        lock.lock()
        guard !destroyed else {
            lock.unlock()
            return
        }
        lock.unlock()

        try api.destroyAggregateDevice(id)

        lock.lock()
        destroyed = true
        lock.unlock()
    }

    deinit {
        try? destroy()
    }

    private static func readBufferFrameSize(for aggregateID: AudioObjectID) throws -> Int {
        let frames: UInt32 = try CoreAudioProperty.get(
            objectID: aggregateID,
            address: CoreAudioProperty.address(kAudioDevicePropertyBufferFrameSize),
            as: UInt32.self
        )
        guard frames > 0 else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }
        return Int(frames)
    }

    private static func totalInputChannelCount(for streams: [InputStreamDescriptor]) throws -> Int {
        var cursor = 0
        for stream in streams.sorted(by: { $0.startingChannelIndex < $1.startingChannelIndex }) {
            guard stream.channelCount > 0, stream.startingChannelIndex == cursor else {
                throw ChannelMapError.nonContiguousChannels
            }
            cursor += stream.channelCount
        }
        return cursor
    }
}

private final class CreatedAggregateOwnership: CaptureAggregateDeviceDestroying, @unchecked Sendable {
    private let id: AudioObjectID
    private let api: any CoreAudioAggregateDeviceAPI
    private let lock = NSLock()
    private var ownsAggregate = true

    init(id: AudioObjectID, api: any CoreAudioAggregateDeviceAPI) {
        self.id = id
        self.api = api
    }

    deinit {
        try? destroy()
    }

    func destroy() throws {
        lock.lock()
        guard ownsAggregate else {
            lock.unlock()
            return
        }
        lock.unlock()

        try api.destroyAggregateDevice(id)

        lock.lock()
        ownsAggregate = false
        lock.unlock()
    }

    func transferOwnership() {
        lock.lock()
        ownsAggregate = false
        lock.unlock()
    }
}

struct CoreAudioCaptureAggregateDeviceFactory: CaptureAggregateDeviceMaking {
    func createMicOnlyAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor]
    ) throws -> any CaptureAggregateDeviceManaging {
        try CaptureAggregateDevice.createMicOnly(
            microphoneUID: microphoneUID,
            microphoneStreams: microphoneStreams
        )
    }

    func createSystemOnlyAggregate(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int
    ) throws -> any CaptureAggregateDeviceManaging {
        try CaptureAggregateDevice.createSystemOnly(
            outputUID: outputUID,
            tapUID: tapUID,
            tapChannelCount: tapChannelCount
        )
    }

    func createMicAndSystemAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) throws -> any CaptureAggregateDeviceManaging {
        try CaptureAggregateDevice.createMicAndSystem(
            microphoneUID: microphoneUID,
            microphoneStreams: microphoneStreams,
            outputUID: outputUID,
            tapUID: tapUID,
            tapChannelCount: tapChannelCount,
            clockSource: clockSource
        )
    }
}
