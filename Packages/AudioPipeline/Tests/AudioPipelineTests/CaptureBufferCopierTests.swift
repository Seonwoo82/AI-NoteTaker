@testable import AudioPipeline
import CoreAudio
import CoreAudioTypes
import Dispatch
import Testing

@Test("Capture buffer copier writes mono input as canonical mono frames")
func captureBufferCopierWritesMonoInputAsCanonicalMonoFrames() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
        inputChannelCount: 1,
        maxFramesPerCycle: 4
    )
    let mono: [Float] = [0.25, -0.5, 0.75]

    let accepted = try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: mono)]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 3)
    #expect(try readFrames(from: ring, frameCount: 3) == [0.25, -0.5, 0.75])
}
@Test("Capture buffer copier preserves one interleaved stereo buffer")
func captureBufferCopierPreservesOneInterleavedStereoBuffer() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 2)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 2)],
        inputChannelCount: 2,
        maxFramesPerCycle: 4
    )
    let stereo: [Float] = [1, 10, 2, 20, 3, 30]

    let accepted = try withAudioBufferList(buffers: [TestAudioBuffer(channels: 2, samples: stereo)]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 3)
    #expect(try readFrames(from: ring, frameCount: 3) == [1, 10, 2, 20, 3, 30])
}

@Test("Capture buffer copier interleaves stream-configured non-interleaved stereo buffers")
func captureBufferCopierInterleavesStreamConfiguredNonInterleavedStereoBuffers() throws {
    let channelMap = try ChannelMapResolver.resolve(
        aggregateStreams: [
            InputStreamDescriptor(
                bufferIndex: 0,
                startingChannelIndex: 0,
                channelCount: 2,
                terminalType: .unknown,
                name: "System Tap"
            )
        ],
        inputBufferChannelCounts: [1, 1],
        microphoneStreams: [],
        tapChannelCount: 2
    )
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 2)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: channelMap.bufferLayout,
        inputChannelCount: 2,
        maxFramesPerCycle: 4
    )
    let left: [Float] = [1, 2, 3]
    let right: [Float] = [10, 20, 30]

    let accepted = try withAudioBufferList(buffers: [
        TestAudioBuffer(channels: 1, samples: left),
        TestAudioBuffer(channels: 1, samples: right)
    ]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 3)
    #expect(try readFrames(from: ring, frameCount: 3) == [1, 10, 2, 20, 3, 30])
}

@Test("Capture buffer copier zero fills nil required input buffers and counts them")
func captureBufferCopierZeroFillsNilRequiredInputBuffersAndCountsThem() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 2)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [
            InputBufferLayout(bufferIndex: 0, channelCount: 1),
            InputBufferLayout(bufferIndex: 1, channelCount: 1)
        ],
        inputChannelCount: 2,
        maxFramesPerCycle: 4
    )
    let left: [Float] = [1, 2, 3]

    let accepted = try withAudioBufferList(buffers: [
        TestAudioBuffer(channels: 1, samples: left),
        TestAudioBuffer(channels: 1, nilFrameCount: 3)
    ]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 3)
    #expect(context.nilInputBufferCount.load(ordering: .relaxed) == 1)
    #expect(try readFrames(from: ring, frameCount: 3) == [1, 0, 2, 0, 3, 0])
}

@Test("Capture buffer copier drops cycles with mismatched layout")
func captureBufferCopierDropsCyclesWithMismatchedLayout() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 2)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 2)],
        inputChannelCount: 2,
        maxFramesPerCycle: 4
    )
    let left: [Float] = [1, 2, 3]
    let right: [Float] = [10, 20, 30]

    let accepted = try withAudioBufferList(buffers: [
        TestAudioBuffer(channels: 1, samples: left),
        TestAudioBuffer(channels: 1, samples: right)
    ]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 0)
    #expect(ring.availableFrames == 0)
    #expect(context.layoutMismatchCount.load(ordering: .relaxed) == 1)
}

@Test("Capture buffer copier drops cycles beyond preallocated frame capacity")
func captureBufferCopierDropsCyclesBeyondPreallocatedFrameCapacity() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
        inputChannelCount: 1,
        maxFramesPerCycle: 2
    )
    let mono: [Float] = [1, 2, 3]

    let accepted = try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: mono)]) { inputData in
        CaptureBufferCopier.copy(inputData: inputData, inputTime: nil, context: context)
    }

    #expect(accepted == 0)
    #expect(ring.availableFrames == 0)
    #expect(context.frameCapacityExceededCount.load(ordering: .relaxed) == 1)
}

@Test("Capture buffer copier counts discontinuous valid input sample times")
func captureBufferCopierCountsDiscontinuousValidInputSampleTimes() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let context = try CaptureContext(
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
        inputChannelCount: 1,
        maxFramesPerCycle: 4
    )
    let first: [Float] = [1, 2]
    let second: [Float] = [3, 4]
    var firstTime = inputSampleTime(100)
    var secondTime = inputSampleTime(103)

    _ = try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: first)]) { inputData in
        withUnsafePointer(to: &firstTime) { inputTime in
            CaptureBufferCopier.copy(inputData: inputData, inputTime: inputTime, context: context)
        }
    }
    let accepted = try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: second)]) { inputData in
        withUnsafePointer(to: &secondTime) { inputTime in
            CaptureBufferCopier.copy(inputData: inputData, inputTime: inputTime, context: context)
        }
    }

    #expect(accepted == 2)
    #expect(context.sampleTimeGapCount.load(ordering: .relaxed) == 1)
    #expect(try readFrames(from: ring, frameCount: 4) == [1, 2, 3, 4])
}
