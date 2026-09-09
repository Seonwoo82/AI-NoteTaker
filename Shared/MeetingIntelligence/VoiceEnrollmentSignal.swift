import Foundation

/// Measures input activity, not speech identity. Speech validation runs on Core ML.
nonisolated struct VoiceEnrollmentSignal {
    static let minimumInputRMS: Float = 0.0003
    let rms: Float
    let activeDuration: Double

    var meterLevel: Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(rms)) + 80) / 60))
    }

    static func measure(_ samples: [Float], sampleRate: Double) -> Self {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 384_000,
              !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            return Self(rms: 0, activeDuration: 0)
        }
        let frameLength = max(1, Int(sampleRate * 0.02))
        var totalEnergy: Double = 0
        var activeSamples = 0
        for start in stride(from: 0, to: samples.count, by: frameLength) {
            let end = min(samples.count, start + frameLength)
            var energy: Double = 0
            for index in start..<end { energy += Double(samples[index]) * Double(samples[index]) }
            totalEnergy += energy
            if sqrt(energy / Double(end - start)) >= Double(minimumInputRMS) { activeSamples += end - start }
        }
        return Self(rms: Float(sqrt(totalEnergy / Double(samples.count))), activeDuration: Double(activeSamples) / sampleRate)
    }

    /// Remove DC and quiet edges, then apply bounded gain without clipping.
    static func prepared16kSamples(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.count <= 480_320, samples.allSatisfy({ $0.isFinite && abs($0) <= 4 }) else {
            throw AIError(message: String(localized: "Voice recording data is invalid. Please record again."))
        }
        let mean = samples.reduce(Double(0)) { $0 + Double($1) } / Double(samples.count)
        let centered = samples.map { Float(Double($0) - mean) }
        let frameLength = 320
        var firstActive: Int?
        var lastActive = 0
        var activeEnergy: Double = 0
        var activeCount = 0
        var peak: Float = 0
        for start in stride(from: 0, to: centered.count, by: frameLength) {
            let end = min(centered.count, start + frameLength)
            var energy: Double = 0
            for index in start..<end {
                energy += Double(centered[index]) * Double(centered[index])
                peak = max(peak, abs(centered[index]))
            }
            if sqrt(energy / Double(end - start)) >= Double(minimumInputRMS) {
                firstActive = firstActive ?? start
                lastActive = end
                activeEnergy += energy
                activeCount += end - start
            }
        }
        guard let firstActive, activeCount >= 16_000, peak > 0 else {
            throw AIError(message: String(localized: "No usable microphone signal was recorded. Check the microphone and try again."))
        }
        let activeRMS = Float(sqrt(activeEnergy / Double(activeCount)))
        let gain = min(32, max(1, 0.04 / activeRMS), 0.95 / peak)
        let start = max(0, firstActive - 1_600)
        let end = min(centered.count, lastActive + 1_600)
        return centered[start..<end].map { $0 * gain }
    }
}
