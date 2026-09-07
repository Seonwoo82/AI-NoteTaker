import AVFAudio
import Foundation

nonisolated enum WaveformSampler {
    static func peaks(from url: URL, bucketCount: Int = 96) -> [Double] {
        guard bucketCount > 0 else { return [] }
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
                return []
            }
            let populatedBuckets = min(Int64(bucketCount), file.length)
            var result = Array(repeating: 0.0, count: bucketCount)
            var bucket: Int64 = 0
            var position: Int64 = 0
            // Quotient/remainder keeps the bucket boundary calculation in Int64
            // without multiplying a potentially long recording's frame count.
            func endOfBucket(_ index: Int64) -> Int64 {
                (file.length / populatedBuckets) * (index + 1)
                    + (file.length % populatedBuckets) * (index + 1) / populatedBuckets
            }
            var bucketEnd = endOfBucket(bucket)
            while position < file.length {
                guard !Task.isCancelled else { return [] }
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    while position >= bucketEnd, bucket + 1 < populatedBuckets {
                        bucket += 1
                        bucketEnd = endOfBucket(bucket)
                    }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        result[Int(bucket)] = max(result[Int(bucket)], sanitizedPeak(channels[channel][frame]))
                    }
                    position += 1
                }
            }
            return result
        } catch {
            return []
        }
    }

    static func downsample(_ samples: [Float], bucketCount: Int) -> [Double] {
        guard bucketCount > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: bucketCount) }
        guard bucketCount < samples.count else {
            return samples.map(sanitizedPeak) + Array(repeating: 0, count: bucketCount - samples.count)
        }

        return (0..<bucketCount).map { bucket in
            let start = bucket * samples.count / bucketCount
            let end = max(start + 1, (bucket + 1) * samples.count / bucketCount)
            let peak = samples[start..<min(end, samples.count)]
                .map(sanitizedPeak)
                .max() ?? 0
            return peak
        }
    }

    private static func sanitizedPeak(_ sample: Float) -> Double {
        guard sample.isFinite else { return 0 }
        return min(1, Double(abs(sample)))
    }
}
