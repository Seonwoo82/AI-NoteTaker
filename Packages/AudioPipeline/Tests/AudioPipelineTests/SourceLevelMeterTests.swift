import AudioPipeline
import Testing

@Test("Source level meter reports microphone and system peaks independently after gains")
func sourceLevelMeterReportsIndependentGainAdjustedPeaks() {
    let input: [Float] = [
        0.25, -0.75, 0.1, -0.4,
        -0.5, 0.125, -0.2, 0.3
    ]
    let layout = MixChannelLayout(microphoneChannels: [0, 1], systemChannels: [2, 3])

    let peaks = input.withUnsafeBufferPointer { buffer in
        SourceLevelMeter.peaks(
            input: buffer,
            frameCount: 2,
            inputChannelCount: 4,
            layout: layout,
            microphoneGain: 2,
            systemGain: 3
        )
    }

    expect(peaks.microphone, equals: 1.5)
    expect(peaks.system, equals: 1.2)
}

@Test("Source level meter reports zero for missing sources")
func sourceLevelMeterReportsZeroForMissingSources() {
    let input: [Float] = [0.25, -0.5]
    let layout = MixChannelLayout(microphoneChannels: [], systemChannels: [])

    let peaks = input.withUnsafeBufferPointer { buffer in
        SourceLevelMeter.peaks(
            input: buffer,
            frameCount: 1,
            inputChannelCount: 2,
            layout: layout,
            microphoneGain: 8,
            systemGain: 8
        )
    }

    #expect(peaks == SourcePeaks(microphone: 0, system: 0))
}

@Test("Source level meter sanitizes non-finite source samples")
func sourceLevelMeterSanitizesNonFiniteSourceSamples() {
    let input: [Float] = [Float.nan, 0.25, Float.infinity, -Float.infinity]
    let layout = MixChannelLayout(microphoneChannels: [0, 1], systemChannels: [2, 3])

    let peaks = input.withUnsafeBufferPointer { buffer in
        SourceLevelMeter.peaks(
            input: buffer,
            frameCount: 1,
            inputChannelCount: 4,
            layout: layout,
            microphoneGain: 2,
            systemGain: 3
        )
    }

    expect(peaks.microphone, equals: 0.5)
    expect(peaks.system, equals: 0)
}

private func expect(
    _ actual: Float,
    equals expected: Float,
    tolerance: Float = 0.000_001,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
}
