import AudioPipeline
import Testing

@Test("Mix kernel duplicates mono microphone input to stereo output")
func mixKernelDuplicatesMonoMicrophoneInputToStereoOutput() {
    let input: [Float] = [0.25, -0.5]
    var output = Array<Float>(repeating: 99, count: 4)
    let layout = MixChannelLayout(microphoneChannels: [0], systemChannels: [])

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            MixKernel.mix(
                input: inputBuffer,
                frameCount: 2,
                inputChannelCount: 1,
                layout: layout,
                microphoneGain: 1,
                systemGain: 1,
                output: outputBuffer
            )
        }
    }

    expect(output, equals: [0.25, 0.25, -0.5, -0.5])
}

@Test("Mix kernel averages stereo microphone input before copying to stereo output")
func mixKernelAveragesStereoMicrophoneInputBeforeCopyingToStereoOutput() {
    let input: [Float] = [0.2, 0.6]
    var output = Array<Float>(repeating: 99, count: 2)
    let layout = MixChannelLayout(microphoneChannels: [0, 1], systemChannels: [])

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            MixKernel.mix(
                input: inputBuffer,
                frameCount: 1,
                inputChannelCount: 2,
                layout: layout,
                microphoneGain: 1,
                systemGain: 1,
                output: outputBuffer
            )
        }
    }

    expect(output, equals: [0.4, 0.4])
}

@Test("Mix kernel applies microphone and system gains before summing stereo output")
func mixKernelAppliesSourceGainsBeforeSummingStereoOutput() {
    let input: [Float] = [0.25, 0.1, -0.2]
    var output = Array<Float>(repeating: 99, count: 2)
    let layout = MixChannelLayout(microphoneChannels: [0], systemChannels: [1, 2])

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            MixKernel.mix(
                input: inputBuffer,
                frameCount: 1,
                inputChannelCount: 3,
                layout: layout,
                microphoneGain: 2,
                systemGain: 1,
                output: outputBuffer
            )
        }
    }

    expect(output, equals: [0.6, 0.3])
}

@Test("Mix kernel emits exact zero when both source gains are zero")
func mixKernelEmitsExactZeroWhenBothSourceGainsAreZero() {
    let input: [Float] = [Float.nan, 0.25, -0.5]
    var output = Array<Float>(repeating: 99, count: 2)
    let layout = MixChannelLayout(microphoneChannels: [0], systemChannels: [1, 2])

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            MixKernel.mix(
                input: inputBuffer,
                frameCount: 1,
                inputChannelCount: 3,
                layout: layout,
                microphoneGain: 0,
                systemGain: 0,
                output: outputBuffer
            )
        }
    }

    #expect(output == [0, 0])
}

@Test("Mix kernel sanitizes non-finite source samples before mixing")
func mixKernelSanitizesNonFiniteSourceSamplesBeforeMixing() {
    let input: [Float] = [Float.nan, Float.infinity, -Float.infinity]
    var output = Array<Float>(repeating: 99, count: 2)
    let layout = MixChannelLayout(microphoneChannels: [0], systemChannels: [1, 2])

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            MixKernel.mix(
                input: inputBuffer,
                frameCount: 1,
                inputChannelCount: 3,
                layout: layout,
                microphoneGain: 2,
                systemGain: 3,
                output: outputBuffer
            )
        }
    }

    #expect(output == [0, 0])
}

@Test("Mix kernel soft clip follows the planned knee behavior")
func mixKernelSoftClipFollowsPlannedKneeBehavior() {
    #expect(MixKernel.softClip(0.8) == 0.8)
    #expect(MixKernel.softClip(-0.8) == -0.8)

    expect(MixKernel.softClip(0.799), equals: 0.799, tolerance: 0.000_001)
    expect(MixKernel.softClip(0.801), equals: 0.800_999_94, tolerance: 0.000_001)
    expect(MixKernel.softClip(-0.801), equals: -0.800_999_94, tolerance: 0.000_001)

    var previous = MixKernel.softClip(-4)
    for value in stride(from: Float(-3.75), through: Float(4), by: Float(0.25)) {
        let clipped = MixKernel.softClip(value)

        #expect(clipped.isFinite)
        #expect(clipped >= previous)
        expect(MixKernel.softClip(-value), equals: -clipped)
        if abs(value) > MixKernel.knee {
            #expect(abs(clipped) < 1)
        }

        previous = clipped
    }
}

private func expect(
    _ actual: [Float],
    equals expected: [Float],
    tolerance: Float = 0.000_001,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)

    for index in 0..<min(actual.count, expected.count) {
        expect(actual[index], equals: expected[index], tolerance: tolerance, sourceLocation: sourceLocation)
    }
}

private func expect(
    _ actual: Float,
    equals expected: Float,
    tolerance: Float = 0.000_001,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
}
