import Foundation

/// Absolute audio times shown by a waveform. Pointer positions map through this
/// range, rather than through the duration of the complete recording.
nonisolated struct WaveformViewport: Equatable {
    let totalDuration: TimeInterval
    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }

    init(duration: TimeInterval, currentTime: TimeInterval, span: TimeInterval = 300) {
        totalDuration = duration.isFinite ? max(0, duration) : 0
        let width = min(totalDuration, span.isFinite && span > 0 ? span : 300)
        let playhead = currentTime.isFinite ? min(totalDuration, max(0, currentTime)) : 0
        start = min(max(0, playhead - width / 2), max(0, totalDuration - width))
        end = min(totalDuration, start + width)
    }

    func time(at fraction: Double) -> TimeInterval {
        start + duration * (fraction.isFinite ? min(1, max(0, fraction)) : 0)
    }

    func position(of time: TimeInterval) -> Double {
        guard duration > 0, time.isFinite else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }

    func peaks(from values: [Double], barCount: Int = 96) -> [Double] {
        guard totalDuration > 0, duration > 0, !values.isEmpty, barCount > 0 else { return [] }
        let count = min(barCount, values.count)
        return (0..<count).map { index in
            let lowerTime = time(at: Double(index) / Double(count))
            let upperTime = time(at: Double(index + 1) / Double(count))
            let lower = min(values.count - 1, max(0, Int(floor(lowerTime / totalDuration * Double(values.count)))))
            let upper = min(values.count, max(lower + 1, Int(ceil(upperTime / totalDuration * Double(values.count)))))
            return values[lower..<upper].reduce(0) { result, value in
                max(result, value.isFinite ? min(1, max(0, value)) : 0)
            }
        }
    }

    static func overviewPeaks(_ values: [Double], barCount: Int = 96) -> [Double] {
        // A synthetic duration keeps live waveforms drawable before their first
        // elapsed-time update, and bounds Canvas work for detailed file data.
        WaveformViewport(duration: 1, currentTime: 0, span: 1).peaks(from: values, barCount: barCount)
    }
}
