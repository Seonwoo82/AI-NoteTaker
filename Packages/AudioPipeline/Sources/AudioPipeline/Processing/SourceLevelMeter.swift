public struct SourcePeaks: Equatable, Sendable {
    public let microphone: Float
    public let system: Float

    public init(microphone: Float, system: Float) {
        self.microphone = microphone
        self.system = system
    }
}

public enum SourceLevelMeter {
    public static func peaks(
        input: UnsafeBufferPointer<Float>,
        frameCount: Int,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        microphoneGain: Float,
        systemGain: Float
    ) -> SourcePeaks {
        guard frameCount > 0, inputChannelCount > 0 else {
            return SourcePeaks(microphone: 0, system: 0)
        }

        var microphonePeak: Float = 0
        var systemPeak: Float = 0

        for frameIndex in 0..<frameCount {
            let frameOffset = frameIndex * inputChannelCount

            for channel in layout.microphoneChannels {
                let value = MixKernel.sample(
                    input: input,
                    frameOffset: frameOffset,
                    inputChannelCount: inputChannelCount,
                    channel: channel
                ) * microphoneGain
                microphonePeak = max(microphonePeak, abs(value))
            }

            for channel in layout.systemChannels {
                let value = MixKernel.sample(
                    input: input,
                    frameOffset: frameOffset,
                    inputChannelCount: inputChannelCount,
                    channel: channel
                ) * systemGain
                systemPeak = max(systemPeak, abs(value))
            }
        }

        return SourcePeaks(microphone: microphonePeak, system: systemPeak)
    }
}
