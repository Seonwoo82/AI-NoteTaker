import Foundation

nonisolated public struct LiveAudioSamples: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let startTime: Double

    public init(samples: [Float], sampleRate: Double, startTime: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }
}

public typealias LiveAudioSampleHandler = @Sendable (LiveAudioSamples) -> Void
