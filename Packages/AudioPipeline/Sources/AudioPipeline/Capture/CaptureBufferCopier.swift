import CoreAudio
import CoreAudioTypes
import Synchronization

enum CaptureBufferCopier {
    private static let audioBufferListHeaderByteSize =
        MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    private static let floatStride = MemoryLayout<Float>.stride

    @inline(__always)
    static nonisolated func copy(
        inputData: UnsafePointer<AudioBufferList>?,
        inputTime: UnsafePointer<AudioTimeStamp>?,
        context: CaptureContext
    ) -> Int {
        guard let inputData else {
            context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
            return 0
        }

        let expectedBufferCount = context.expectedBufferCount
        guard Int(inputData.pointee.mNumberBuffers) == expectedBufferCount else {
            context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
            return 0
        }

        let buffers = UnsafeRawPointer(inputData)
            .advanced(by: audioBufferListHeaderByteSize)
            .assumingMemoryBound(to: AudioBuffer.self)
        var frameCount = -1
        var channelOffset = 0

        for index in 0..<expectedBufferCount {
            let layout = context.expectedLayoutPointer[index]
            let buffer = buffers[index]
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount == layout.channelCount else {
                context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
                return 0
            }

            let bytesPerFrame = bufferChannelCount * floatStride
            let byteSize = Int(buffer.mDataByteSize)
            guard bytesPerFrame > 0, byteSize.isMultiple(of: bytesPerFrame) else {
                context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
                return 0
            }

            let bufferFrameCount = byteSize / bytesPerFrame
            if frameCount < 0 {
                frameCount = bufferFrameCount
            } else if frameCount != bufferFrameCount {
                context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
                return 0
            }
            channelOffset += bufferChannelCount
        }

        guard channelOffset == context.inputChannelCount, frameCount >= 0 else {
            context.layoutMismatchCount.wrappingAdd(1, ordering: .relaxed)
            return 0
        }
        guard frameCount <= context.maxFramesPerCycle else {
            context.frameCapacityExceededCount.wrappingAdd(1, ordering: .relaxed)
            return 0
        }

        let sampleCount = frameCount * context.inputChannelCount
        context.scratch.update(repeating: 0, count: sampleCount)

        channelOffset = 0
        for index in 0..<expectedBufferCount {
            let layout = context.expectedLayoutPointer[index]
            let buffer = buffers[index]
            if let data = buffer.mData {
                let source = data.assumingMemoryBound(to: Float.self)
                copySource(
                    source,
                    destination: context.scratch,
                    frameCount: frameCount,
                    sourceChannelCount: layout.channelCount,
                    destinationChannelCount: context.inputChannelCount,
                    destinationChannelOffset: channelOffset
                )
            } else if frameCount > 0 {
                context.nilInputBufferCount.wrappingAdd(1, ordering: .relaxed)
            }
            channelOffset += layout.channelCount
        }

        updateSampleTime(inputTime, frameCount: frameCount, context: context)
        let source = UnsafeBufferPointer(start: context.scratch, count: sampleCount)
        return context.ring.write(source, frameCount: frameCount)
    }

    @inline(__always)
    private static nonisolated func copySource(
        _ source: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sourceChannelCount: Int,
        destinationChannelCount: Int,
        destinationChannelOffset: Int
    ) {
        for frameIndex in 0..<frameCount {
            let sourceFrameOffset = frameIndex * sourceChannelCount
            let destinationFrameOffset = (frameIndex * destinationChannelCount) + destinationChannelOffset
            for channelIndex in 0..<sourceChannelCount {
                destination[destinationFrameOffset + channelIndex] = source[sourceFrameOffset + channelIndex]
            }
        }
    }

    @inline(__always)
    private static nonisolated func updateSampleTime(
        _ inputTime: UnsafePointer<AudioTimeStamp>?,
        frameCount: Int,
        context: CaptureContext
    ) {
        guard let inputTime, inputTime.pointee.mFlags.contains(.sampleTimeValid) else {
            return
        }

        let sampleTime = inputTime.pointee.mSampleTime
        if context.hasNextSampleTime.pointee, sampleTime != context.nextSampleTime.pointee {
            context.sampleTimeGapCount.wrappingAdd(1, ordering: .relaxed)
        }
        context.nextSampleTime.pointee = sampleTime + Float64(frameCount)
        context.hasNextSampleTime.pointee = true
    }
}
