import Synchronization

public enum SPSCRingBufferError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case invalidChannelCount(Int)
}

public final class SPSCRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    public let channelCount: Int

    private let sampleCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let readSequence = Atomic<Int>(0)
    private let writeSequence = Atomic<Int>(0)
    private let droppedFrameCounter = Atomic<UInt64>(0)
    private let overflowCounter = Atomic<UInt64>(0)

    public init(capacityFrames: Int, channelCount: Int) throws {
        guard capacityFrames > 0 else {
            throw SPSCRingBufferError.invalidCapacity(capacityFrames)
        }
        guard channelCount > 0 else {
            throw SPSCRingBufferError.invalidChannelCount(channelCount)
        }

        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        self.sampleCapacity = capacityFrames * channelCount
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        self.storage.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        storage.deinitialize(count: sampleCapacity)
        storage.deallocate()
    }

    @inline(__always)
    public func write(_ source: UnsafeBufferPointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else {
            return 0
        }

        let requestedFrames = min(frameCount, source.count / channelCount)
        guard requestedFrames > 0 else {
            return 0
        }

        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        let available = write - read
        let writableFrames = min(requestedFrames, capacityFrames - available)
        let dropped = requestedFrames - writableFrames

        if dropped > 0 {
            droppedFrameCounter.wrappingAdd(UInt64(dropped), ordering: .relaxed)
            overflowCounter.wrappingAdd(1, ordering: .relaxed)
        }

        guard writableFrames > 0, let sourceBase = source.baseAddress else {
            return 0
        }

        copyFromSource(sourceBase, frameCount: writableFrames, writeSequence: write)
        writeSequence.store(write + writableFrames, ordering: .releasing)
        return writableFrames
    }

    @inline(__always)
    public func read(into destination: UnsafeMutableBufferPointer<Float>, maxFrames: Int) -> Int {
        guard maxFrames > 0 else {
            return 0
        }

        let requestedFrames = min(maxFrames, destination.count / channelCount)
        guard requestedFrames > 0 else {
            return 0
        }

        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        let readableFrames = min(requestedFrames, write - read)

        guard readableFrames > 0, let destinationBase = destination.baseAddress else {
            return 0
        }

        copyToDestination(destinationBase, frameCount: readableFrames, readSequence: read)
        readSequence.store(read + readableFrames, ordering: .releasing)
        return readableFrames
    }

    func read(
        into destination: UnsafeMutableBufferPointer<Float>,
        maxFrames: Int,
        upToWriteSequence boundary: Int
    ) -> Int {
        guard maxFrames > 0 else {
            return 0
        }

        let requestedFrames = min(maxFrames, destination.count / channelCount)
        guard requestedFrames > 0 else {
            return 0
        }

        let read = readSequence.load(ordering: .relaxed)
        let write = min(writeSequence.load(ordering: .acquiring), boundary)
        let readableFrames = min(requestedFrames, max(0, write - read))

        guard readableFrames > 0, let destinationBase = destination.baseAddress else {
            return 0
        }

        copyToDestination(destinationBase, frameCount: readableFrames, readSequence: read)
        readSequence.store(read + readableFrames, ordering: .releasing)
        return readableFrames
    }

    var writeSequenceSnapshot: Int {
        writeSequence.load(ordering: .acquiring)
    }

    public var availableFrames: Int {
        let write = writeSequence.load(ordering: .acquiring)
        let read = readSequence.load(ordering: .acquiring)
        return write - read
    }

    public var droppedFrames: UInt64 {
        droppedFrameCounter.load(ordering: .relaxed)
    }

    public var overflowCount: UInt64 {
        overflowCounter.load(ordering: .relaxed)
    }

    @inline(__always)
    private func copyFromSource(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        writeSequence: Int
    ) {
        let firstFrameIndex = writeSequence % capacityFrames
        let firstFrameCount = min(frameCount, capacityFrames - firstFrameIndex)
        let firstSampleCount = firstFrameCount * channelCount
        let storageOffset = firstFrameIndex * channelCount

        storage.advanced(by: storageOffset).update(from: source, count: firstSampleCount)

        let remainingFrames = frameCount - firstFrameCount
        if remainingFrames > 0 {
            storage.update(
                from: source.advanced(by: firstSampleCount),
                count: remainingFrames * channelCount
            )
        }
    }

    @inline(__always)
    private func copyToDestination(
        _ destination: UnsafeMutablePointer<Float>,
        frameCount: Int,
        readSequence: Int
    ) {
        let firstFrameIndex = readSequence % capacityFrames
        let firstFrameCount = min(frameCount, capacityFrames - firstFrameIndex)
        let firstSampleCount = firstFrameCount * channelCount
        let storageOffset = firstFrameIndex * channelCount

        destination.update(from: storage.advanced(by: storageOffset), count: firstSampleCount)

        let remainingFrames = frameCount - firstFrameCount
        if remainingFrames > 0 {
            destination.advanced(by: firstSampleCount).update(
                from: storage,
                count: remainingFrames * channelCount
            )
        }
    }
}
