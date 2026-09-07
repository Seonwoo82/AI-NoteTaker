import AudioPipeline
import Foundation
import Testing

@Test("Bar accumulator emits peak and RMS for a full constant stereo bin")
func barAccumulatorEmitsPeakAndRMSForFullConstantStereoBin() throws {
    var accumulator = try BarAccumulator(sampleRate: 1_000)
    let samples = Array<Float>(repeating: 0.5, count: 20)

    samples.withUnsafeBufferPointer { buffer in
        accumulator.ingest(buffer, frameCount: 10, channelCount: 2)
    }

    let bars = accumulator.drainCompleted()

    #expect(bars.count == 1)
    #expect(bars.first?.frameCount == 10)
    expect(bars.first?.peak, equals: 0.5)
    expect(bars.first?.rms, equals: 0.5)
    #expect(accumulator.totalFrames == 10)
}

@Test("Bar accumulator computes scalar RMS across all channel samples")
func barAccumulatorComputesScalarRMSAcrossAllChannelSamples() throws {
    var accumulator = try BarAccumulator(sampleRate: 1_000)
    let samples: [Float] = [1, -1, 0, 0]

    samples.withUnsafeBufferPointer { buffer in
        accumulator.ingest(buffer, frameCount: 2, channelCount: 2)
    }

    let bars = accumulator.finish()

    #expect(bars.count == 1)
    #expect(bars.first?.frameCount == 2)
    expect(bars.first?.peak, equals: 1)
    expect(bars.first?.rms, equals: Float(sqrt(0.5)))
}

@Test("Bar accumulator emits the same bars regardless of chunk boundaries")
func barAccumulatorEmitsSameBarsRegardlessOfChunkBoundaries() throws {
    let samples = alternatingStereoSamples(frameCount: 250)

    let oneChunk = try accumulatedBars(
        sampleRate: 1_000,
        samples: samples,
        channelCount: 2,
        chunks: [250]
    )
    let splitChunks = try accumulatedBars(
        sampleRate: 1_000,
        samples: samples,
        channelCount: 2,
        chunks: [100, 75, 75]
    )

    #expect(oneChunk == splitChunks)
    #expect(oneChunk.count == 25)
    #expect(oneChunk.map(\.frameCount).allSatisfy { $0 == 10 })
}

@Test("Bar accumulator emits unfinished frames only when finished")
func barAccumulatorEmitsUnfinishedFramesOnlyWhenFinished() throws {
    var accumulator = try BarAccumulator(sampleRate: 1_000)
    let samples = Array<Float>(repeating: 0.25, count: 14)

    samples.withUnsafeBufferPointer { buffer in
        accumulator.ingest(buffer, frameCount: 7, channelCount: 2)
    }

    #expect(accumulator.drainCompleted().isEmpty)

    let finished = accumulator.finish()
    #expect(finished.count == 1)
    #expect(finished.first?.frameCount == 7)
    expect(finished.first?.peak, equals: 0.25)
    expect(finished.first?.rms, equals: 0.25)
}

@Test("Bar accumulator finish is idempotent")
func barAccumulatorFinishIsIdempotent() throws {
    var accumulator = try BarAccumulator(sampleRate: 1_000)
    let samples = Array<Float>(repeating: -0.5, count: 14)

    samples.withUnsafeBufferPointer { buffer in
        accumulator.ingest(buffer, frameCount: 7, channelCount: 2)
    }

    let first = accumulator.finish()
    let second = accumulator.finish()

    #expect(first.count == 1)
    #expect(second.isEmpty)
}

@Test("Bar accumulator uses absolute frame boundaries at common audio rates")
func barAccumulatorUsesAbsoluteFrameBoundariesAtCommonAudioRates() throws {
    for sampleRate in [44_100.0, 48_000.0] {
        let frameCount = Int(sampleRate)
        let samples = alternatingStereoSamples(frameCount: frameCount)

        let oneChunk = try accumulatedBars(
            sampleRate: sampleRate,
            samples: samples,
            channelCount: 2,
            chunks: [frameCount]
        )
        let splitChunks = try accumulatedBars(
            sampleRate: sampleRate,
            samples: samples,
            channelCount: 2,
            chunks: [137, 509, 4_096, 333, 20_000, frameCount]
        )

        #expect(oneChunk == splitChunks)
        #expect(oneChunk.reduce(0) { $0 + $1.frameCount } == frameCount)
    }
}

private func accumulatedBars(
    sampleRate: Double,
    samples: [Float],
    channelCount: Int,
    chunks: [Int]
) throws -> [AudioBar] {
    var accumulator = try BarAccumulator(sampleRate: sampleRate)
    var sampleOffset = 0
    var remainingFrames = samples.count / channelCount

    for chunk in chunks where remainingFrames > 0 {
        let frameCount = min(chunk, remainingFrames)
        let sampleCount = frameCount * channelCount
        samples.withUnsafeBufferPointer { buffer in
            let chunkBuffer = UnsafeBufferPointer(rebasing: buffer[sampleOffset..<(sampleOffset + sampleCount)])
            accumulator.ingest(chunkBuffer, frameCount: frameCount, channelCount: channelCount)
        }
        sampleOffset += sampleCount
        remainingFrames -= frameCount
    }

    return accumulator.drainCompleted() + accumulator.finish()
}

private func alternatingStereoSamples(frameCount: Int) -> [Float] {
    var samples = Array<Float>(repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        samples[frame * 2] = frame.isMultiple(of: 2) ? 0.25 : -0.75
        samples[frame * 2 + 1] = frame.isMultiple(of: 3) ? 0.5 : -0.5
    }
    return samples
}

private func expect(
    _ actual: Float?,
    equals expected: Float,
    tolerance: Float = 0.000_001,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual != nil, sourceLocation: sourceLocation)
    if let actual {
        #expect(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
    }
}
