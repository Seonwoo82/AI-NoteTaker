@testable import AudioPipeline
import CoreAudio
import CoreAudioTypes
import Dispatch
import Testing

@Test("Capture IOProc writes accepted input frames and signals wake once")
func captureIOProcWritesAcceptedInputFramesAndSignalsWakeOnce() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let wake = DispatchSemaphore(value: 0)
    let context = try CaptureContext(
        ring: ring,
        wake: wake,
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
        inputChannelCount: 1,
        maxFramesPerCycle: 4
    )
    let block = CaptureIOProc.makeBlock(context: context)
    let mono: [Float] = [0.5, -0.25]

    try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: mono)]) { inputData in
        callAudioDeviceIOBlock(block, inputData: inputData)
    }

    #expect(wake.wait(timeout: .now()) == .success)
    #expect(wake.wait(timeout: .now()) == .timedOut)
    #expect(try readFrames(from: ring, frameCount: 2) == [0.5, -0.25])
}

@Test("Capture IOProc does not signal wake after a dropped cycle")
func captureIOProcDoesNotSignalWakeAfterDroppedCycle() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let wake = DispatchSemaphore(value: 0)
    let context = try CaptureContext(
        ring: ring,
        wake: wake,
        expectedLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
        inputChannelCount: 1,
        maxFramesPerCycle: 1
    )
    let block = CaptureIOProc.makeBlock(context: context)
    let mono: [Float] = [1, 2]

    try withAudioBufferList(buffers: [TestAudioBuffer(channels: 1, samples: mono)]) { inputData in
        callAudioDeviceIOBlock(block, inputData: inputData)
    }

    #expect(wake.wait(timeout: .now()) == .timedOut)
    #expect(ring.availableFrames == 0)
    #expect(context.frameCapacityExceededCount.load(ordering: .relaxed) == 1)
}

final class TestAudioBuffer {
    let channels: UInt32
    let byteSize: UInt32
    let dataPointer: UnsafeMutablePointer<Float>?
    var data: UnsafeMutableRawPointer? {
        if let dataPointer {
            UnsafeMutableRawPointer(dataPointer)
        } else {
            nil
        }
    }

    init(channels: UInt32, samples: [Float]) {
        self.channels = channels
        self.byteSize = UInt32(samples.count * MemoryLayout<Float>.stride)
        self.dataPointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        for (index, sample) in samples.enumerated() {
            dataPointer?.advanced(by: index).initialize(to: sample)
        }
    }

    init(channels: UInt32, nilFrameCount: Int) {
        self.channels = channels
        self.byteSize = UInt32(nilFrameCount * Int(channels) * MemoryLayout<Float>.stride)
        self.dataPointer = nil
    }

    deinit {
        let sampleCount = Int(byteSize) / MemoryLayout<Float>.stride
        dataPointer?.deinitialize(count: sampleCount)
        dataPointer?.deallocate()
    }
}

func withAudioBufferList<Result>(
    buffers: [TestAudioBuffer],
    _ body: (UnsafePointer<AudioBufferList>) throws -> Result
) throws -> Result {
    let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let bufferStride = MemoryLayout<AudioBuffer>.stride
    let byteCount = headerSize + (buffers.count * bufferStride)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    storage.storeBytes(of: UInt32(buffers.count), as: UInt32.self)
    for (index, testBuffer) in buffers.enumerated() {
        let audioBuffer = AudioBuffer(
            mNumberChannels: testBuffer.channels,
            mDataByteSize: testBuffer.byteSize,
            mData: testBuffer.data
        )
        storage
            .advanced(by: headerSize + (index * bufferStride))
            .storeBytes(of: audioBuffer, as: AudioBuffer.self)
    }
    return try body(storage.assumingMemoryBound(to: AudioBufferList.self))
}

func readFrames(from ring: SPSCRingBuffer, frameCount: Int) throws -> [Float] {
    var destination = Array<Float>(repeating: -1, count: frameCount * ring.channelCount)
    let read = destination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: frameCount)
    }

    #expect(read == frameCount)
    return destination
}

func inputSampleTime(_ sampleTime: Float64) -> AudioTimeStamp {
    AudioTimeStamp(
        mSampleTime: sampleTime,
        mHostTime: 0,
        mRateScalar: 0,
        mWordClockTime: 0,
        mSMPTETime: SMPTETime(),
        mFlags: .sampleTimeValid,
        mReserved: 0
    )
}

func callAudioDeviceIOBlock(
    _ block: AudioDeviceIOBlock,
    inputData: UnsafePointer<AudioBufferList>
) {
    var now = AudioTimeStamp()
    var inputTime = AudioTimeStamp()
    var outputTime = AudioTimeStamp()
    withUnsafePointer(to: &now) { nowPointer in
        withUnsafePointer(to: &inputTime) { inputTimePointer in
            withUnsafePointer(to: &outputTime) { outputTimePointer in
                block(
                    nowPointer,
                    inputData,
                    inputTimePointer,
                    UnsafeMutablePointer(mutating: inputData),
                    outputTimePointer
                )
            }
        }
    }
}
