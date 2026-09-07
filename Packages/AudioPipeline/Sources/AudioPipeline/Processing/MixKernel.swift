import Darwin

public struct MixChannelLayout: Equatable, Sendable {
    public let microphoneChannels: [Int]
    public let systemChannels: [Int]

    public init(microphoneChannels: [Int], systemChannels: [Int]) {
        self.microphoneChannels = microphoneChannels
        self.systemChannels = systemChannels
    }
}

public enum MixKernel {
    public static let knee: Float = 0.8

    @inline(__always)
    public static func softClip(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > knee else {
            return value
        }

        let sign: Float = value < 0 ? -1 : 1
        let clipped = knee + 0.2 * tanhf((magnitude - knee) / 0.2)
        return sign * min(clipped, Float(1).nextDown)
    }

    public static func mix(
        input: UnsafeBufferPointer<Float>,
        frameCount: Int,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        microphoneGain: Float,
        systemGain: Float,
        output: UnsafeMutableBufferPointer<Float>
    ) {
        guard frameCount > 0, inputChannelCount > 0 else {
            return
        }

        for frameIndex in 0..<frameCount {
            let inputFrameOffset = frameIndex * inputChannelCount
            let outputFrameOffset = frameIndex * 2

            let microphone = average(
                input: input,
                frameOffset: inputFrameOffset,
                inputChannelCount: inputChannelCount,
                channels: layout.microphoneChannels
            ) * microphoneGain
            let systemLeft = sample(
                input: input,
                frameOffset: inputFrameOffset,
                inputChannelCount: inputChannelCount,
                channel: layout.systemChannels.first
            ) * systemGain
            let systemRight = sample(
                input: input,
                frameOffset: inputFrameOffset,
                inputChannelCount: inputChannelCount,
                channel: layout.systemChannels.dropFirst().first
            ) * systemGain

            if output.indices.contains(outputFrameOffset) {
                output[outputFrameOffset] = softClip(microphone + systemLeft)
            }
            if output.indices.contains(outputFrameOffset + 1) {
                output[outputFrameOffset + 1] = softClip(microphone + systemRight)
            }
        }
    }

    @inline(__always)
    static func sample(
        input: UnsafeBufferPointer<Float>,
        frameOffset: Int,
        inputChannelCount: Int,
        channel: Int?
    ) -> Float {
        guard let channel, channel >= 0, channel < inputChannelCount else {
            return 0
        }

        let index = frameOffset + channel
        guard input.indices.contains(index) else {
            return 0
        }

        let value = input[index]
        return value.isFinite ? value : 0
    }

    @inline(__always)
    private static func average(
        input: UnsafeBufferPointer<Float>,
        frameOffset: Int,
        inputChannelCount: Int,
        channels: [Int]
    ) -> Float {
        guard !channels.isEmpty else {
            return 0
        }

        var sum: Float = 0
        var count: Float = 0
        for channel in channels {
            sum += sample(
                input: input,
                frameOffset: frameOffset,
                inputChannelCount: inputChannelCount,
                channel: channel
            )
            count += 1
        }

        return sum / count
    }
}
