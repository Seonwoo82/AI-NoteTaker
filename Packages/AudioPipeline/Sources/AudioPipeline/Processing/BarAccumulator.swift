import Darwin

public struct AudioBar: Equatable, Sendable {
    public let peak: Float
    public let rms: Float
    public let frameCount: Int

    public init(peak: Float, rms: Float, frameCount: Int) {
        self.peak = peak
        self.rms = rms
        self.frameCount = frameCount
    }
}

public enum BarAccumulatorError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case invalidBinsPerSecond(Int)
}

public struct BarAccumulator: Sendable {
    private let sampleRate: Double
    private let binsPerSecond: Int
    private var currentBinIndex = 0
    private var completed: [AudioBar] = []
    private var currentPeak: Float = 0
    private var currentSumSquares: Double = 0
    private var currentSampleCount = 0
    private var currentFrameCount = 0
    private var didFinish = false

    public private(set) var totalFrames = 0

    public init(
        sampleRate: Double,
        binsPerSecond: Int = AudioPipelineConstants.waveformBinsPerSecond
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BarAccumulatorError.invalidSampleRate(sampleRate)
        }
        guard binsPerSecond > 0 else {
            throw BarAccumulatorError.invalidBinsPerSecond(binsPerSecond)
        }

        self.sampleRate = sampleRate
        self.binsPerSecond = binsPerSecond
    }

    public mutating func ingest(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard !didFinish, frameCount > 0, channelCount > 0 else {
            return
        }

        for frameIndex in 0..<frameCount {
            let frameOffset = frameIndex * channelCount
            for channel in 0..<channelCount {
                let sampleIndex = frameOffset + channel
                let value = samples.indices.contains(sampleIndex) && samples[sampleIndex].isFinite
                    ? samples[sampleIndex]
                    : 0
                let magnitude = abs(value)
                currentPeak = max(currentPeak, magnitude)
                currentSumSquares += Double(value * value)
                currentSampleCount += 1
            }

            currentFrameCount += 1
            totalFrames += 1

            if totalFrames >= boundaryFrame(forBin: currentBinIndex + 1) {
                completeCurrentBin()
            }
        }
    }

    public mutating func drainCompleted() -> [AudioBar] {
        defer {
            completed.removeAll(keepingCapacity: true)
        }
        return completed
    }

    public mutating func finish() -> [AudioBar] {
        guard !didFinish else {
            return []
        }

        didFinish = true
        if currentFrameCount > 0 {
            completeCurrentBin()
        }

        return drainCompleted()
    }

    private func boundaryFrame(forBin bin: Int) -> Int {
        Int((Double(bin) * sampleRate / Double(binsPerSecond)).rounded(.down))
    }

    private mutating func completeCurrentBin() {
        guard currentFrameCount > 0 else {
            currentBinIndex += 1
            return
        }

        let rms = currentSampleCount > 0
            ? Float(sqrt(currentSumSquares / Double(currentSampleCount)))
            : 0
        completed.append(
            AudioBar(
                peak: currentPeak,
                rms: rms,
                frameCount: currentFrameCount
            )
        )

        currentBinIndex += 1
        currentPeak = 0
        currentSumSquares = 0
        currentSampleCount = 0
        currentFrameCount = 0
    }
}
