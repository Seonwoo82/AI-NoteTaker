import Dispatch
import Synchronization

public enum CaptureContextError: Error, Equatable, Sendable {
    case invalidExpectedLayout
    case invalidInputChannelCount(Int)
    case invalidMaxFramesPerCycle(Int)
    case ringChannelCountMismatch(expected: Int, actual: Int)
    case scratchCapacityOverflow
}

public final class CaptureContext: @unchecked Sendable {
    public let ring: SPSCRingBuffer
    public let wake: DispatchSemaphore
    public let expectedLayout: [InputBufferLayout]
    public let inputChannelCount: Int
    public let maxFramesPerCycle: Int
    public let layoutMismatchCount = Atomic<UInt64>(0)
    public let frameCapacityExceededCount = Atomic<UInt64>(0)
    public let nilInputBufferCount = Atomic<UInt64>(0)
    public let sampleTimeGapCount = Atomic<UInt64>(0)

    let expectedBufferCount: Int
    let expectedLayoutPointer: UnsafeMutablePointer<InputBufferLayout>
    let scratch: UnsafeMutablePointer<Float>
    let scratchSampleCapacity: Int
    let nextSampleTime: UnsafeMutablePointer<Float64>
    let hasNextSampleTime: UnsafeMutablePointer<Bool>

    public init(
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        expectedLayout: [InputBufferLayout],
        inputChannelCount: Int,
        maxFramesPerCycle: Int
    ) throws {
        guard inputChannelCount > 0 else {
            throw CaptureContextError.invalidInputChannelCount(inputChannelCount)
        }
        guard maxFramesPerCycle > 0 else {
            throw CaptureContextError.invalidMaxFramesPerCycle(maxFramesPerCycle)
        }
        guard ring.channelCount == inputChannelCount else {
            throw CaptureContextError.ringChannelCountMismatch(
                expected: inputChannelCount,
                actual: ring.channelCount
            )
        }

        var channelTotal = 0
        for (index, layout) in expectedLayout.enumerated() {
            guard layout.bufferIndex == index, layout.channelCount > 0 else {
                throw CaptureContextError.invalidExpectedLayout
            }
            channelTotal += layout.channelCount
        }
        guard channelTotal == inputChannelCount else {
            throw CaptureContextError.invalidExpectedLayout
        }

        let capacityResult = maxFramesPerCycle.multipliedReportingOverflow(by: inputChannelCount)
        guard !capacityResult.overflow else {
            throw CaptureContextError.scratchCapacityOverflow
        }

        self.ring = ring
        self.wake = wake
        self.expectedLayout = expectedLayout
        self.inputChannelCount = inputChannelCount
        self.maxFramesPerCycle = maxFramesPerCycle
        self.expectedBufferCount = expectedLayout.count
        self.expectedLayoutPointer = UnsafeMutablePointer<InputBufferLayout>.allocate(capacity: expectedLayout.count)
        self.expectedLayoutPointer.initialize(from: expectedLayout, count: expectedLayout.count)
        self.scratchSampleCapacity = capacityResult.partialValue
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacityResult.partialValue)
        self.scratch.initialize(repeating: 0, count: capacityResult.partialValue)
        self.nextSampleTime = UnsafeMutablePointer<Float64>.allocate(capacity: 1)
        self.nextSampleTime.initialize(to: 0)
        self.hasNextSampleTime = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        self.hasNextSampleTime.initialize(to: false)
    }

    deinit {
        expectedLayoutPointer.deinitialize(count: expectedBufferCount)
        expectedLayoutPointer.deallocate()
        scratch.deinitialize(count: scratchSampleCapacity)
        scratch.deallocate()
        nextSampleTime.deinitialize(count: 1)
        nextSampleTime.deallocate()
        hasNextSampleTime.deinitialize(count: 1)
        hasNextSampleTime.deallocate()
    }
}
