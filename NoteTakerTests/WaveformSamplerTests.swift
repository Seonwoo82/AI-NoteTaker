import Testing
import Foundation
import AVFAudio
@testable import NoteTaker

@Suite
struct WaveformSamplerTests {
    @Test("waveform includes audio after the first two minutes")
    func waveformIncludesAudioAfterFirstTwoMinutes() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "waveform-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let channel = try #require(buffer.floatChannelData?[0])
        for second in 0..<130 {
            channel.update(repeating: second >= 125 ? 0.8 : 0.1, count: 8_000)
            try file.write(from: buffer)
        }
        file.close()
        let peaks = WaveformSampler.peaks(from: url, bucketCount: 13)
        #expect(peaks.count == 13)
        #expect(abs(peaks[0] - 0.1) < 0.001)
        #expect(abs(peaks[12] - 0.8) < 0.001)
    }
    @Test("downsampling records the peak magnitude in each bucket")
    func downsamplingRecordsPeakMagnitudeInEachBucket() {
        let peaks = WaveformSampler.downsample(
            [-0.2, 0.6, 0.1, -0.9, 0.4, 0.3],
            bucketCount: 3
        )

        #expect(peaks.count == 3)
        #expect(abs(peaks[0] - 0.6) < 0.0001)
        #expect(abs(peaks[1] - 0.9) < 0.0001)
        #expect(abs(peaks[2] - 0.4) < 0.0001)
    }

    @Test("downsampling sanitizes nonfinite values and pads empty buckets")
    func downsamplingSanitizesNonfiniteValuesAndPadsEmptyBuckets() {
        let peaks = WaveformSampler.downsample(
            [0.25, .nan, .infinity],
            bucketCount: 5
        )

        #expect(peaks == [0.25, 0, 0, 0, 0])
    }

    @Test("timeline marks expose clamped progress and sparse second labels")
    func timelineMarksExposeClampedProgressAndSparseSecondLabels() {
        let marks = WaveformTimelineMarks(duration: 64, currentTime: 5, interval: 15)

        #expect(abs(marks.progress - 0.078125) < 0.0001)
        #expect(marks.ticks.map(\.time) == [0, 15, 30, 45, 60, 64])
        #expect(marks.ticks.map(\.label) == ["0:00", "0:15", "0:30", "0:45", "1:00", "1:04"])
        #expect(abs(marks.ticks[1].position - 0.234375) < 0.0001)
    }

    @Test("long recordings retain a bounded number of timeline labels")
    func longRecordingsRetainBoundedTimelineLabels() {
        let marks = WaveformTimelineMarks(duration: 86_400, currentTime: 43_200)
        #expect(marks.ticks.count <= 8)
        #expect(marks.ticks.first?.time == 0)
        #expect(marks.ticks.last?.time == 86_400)
        #expect(marks.progress == 0.5)
    }

    @Test("invalid timeline values do not create ticks or nonfinite progress")
    func invalidTimelineValuesAreSafe() {
        let invalidDuration = WaveformTimelineMarks(duration: .infinity, currentTime: .nan)
        #expect(invalidDuration.ticks.isEmpty)
        #expect(invalidDuration.progress == 0)
        let invalidTime = WaveformTimelineMarks(duration: 60, currentTime: .nan)
        #expect(invalidTime.currentTime == 0)
    }
}
