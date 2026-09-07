import Foundation
import Testing
import AudioPipeline
import AVFAudio

@Suite
struct PlaybackTimelineTests {
    @Test("timeline clamps seeks into the playable duration")
    func clampsSeeksIntoPlayableDuration() {
        let timeline = PlaybackTimeline(duration: 42)

        #expect(timeline.clampedSeekTime(-8) == 0)
        #expect(timeline.clampedSeekTime(11.5) == 11.5)
        #expect(timeline.clampedSeekTime(100) == 42)
    }

    @Test("timeline skips exactly fifteen seconds before clamping")
    func skipsExactlyFifteenSecondsBeforeClamping() {
        let timeline = PlaybackTimeline(duration: 40)

        #expect(timeline.skippingBackward(from: 18) == 3)
        #expect(timeline.skippingBackward(from: 8) == 0)
        #expect(timeline.skippingForward(from: 18) == 33)
        #expect(timeline.skippingForward(from: 32) == 40)
    }

    @Test("timeline treats the end as duration")
    func treatsEndAsDuration() {
        let timeline = PlaybackTimeline(duration: 12.25)

        #expect(timeline.endTime == 12.25)
        #expect(timeline.clampedSeekTime(.infinity) == 12.25)
    }

    @MainActor
    @Test("failed load clears the previous audio before play can restart it")
    func failedLoadClearsPreviousAudioBeforePlayCanRestartIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PlaybackEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validURL = root.appending(path: "valid.wav")
        let missingURL = root.appending(path: "missing.wav")
        try writeSineWave(to: validURL, duration: 0.05)

        let engine = PlaybackEngine()
        try engine.load(url: validURL)
        #expect(engine.duration > 0)

        do {
            try engine.load(url: missingURL)
            Issue.record("Loading a missing file should throw")
        } catch {}

        guard engine.duration == 0, engine.currentTime == 0, !engine.isPlaying else {
            Issue.record("Stale audio remains loaded after a failed load")
            return
        }
        #expect(throws: PlaybackEngine.PlaybackError.noLoadedFile) {
            try engine.play()
        }
        #expect(!engine.isPlaying)
    }
}

private func writeSineWave(to url: URL, duration: TimeInterval) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount(duration * format.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let samples = buffer.floatChannelData![0]
    for frame in 0..<Int(frameCount) {
        samples[frame] = sin(Float(frame) * 0.01) * 0.2
    }
    try file.write(from: buffer)
}
