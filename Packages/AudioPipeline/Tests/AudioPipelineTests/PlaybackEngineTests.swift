import AVFAudio
import Foundation
import Testing
@testable import AudioPipeline

@MainActor
@Suite
struct PlaybackEngineTests {
    @Test("resume after pause clears the stale schedule and resumes from the paused frame")
    func resumeAfterPauseClearsStaleSchedule() async throws {
        let url = try writePlaybackTestAudio(frameCount: 1_000)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        try engine.load(url: url)
        driver.events.removeAll()

        try engine.play()
        driver.renderedSampleTimeValue = 120
        engine.pause()
        try engine.play()

        #expect(driver.scheduledSegments.map(\.startingFrame) == [0, 120])
        #expect(driver.scheduledSegments.map(\.frameCount) == [1_000, 880])
        #expect(driver.events == [.schedule, .start, .play, .pause, .stop, .schedule, .play])
        #expect(engine.currentTime == 120.0 / 44_100.0)
        #expect(engine.isPlaying)
    }

    @Test("playback completion waits until data is audibly played back")
    func completionUsesDataPlayedBack() async throws {
        let url = try writePlaybackTestAudio(frameCount: 500)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        try engine.load(url: url)
        driver.events.removeAll()

        try engine.play()

        #expect(driver.scheduledSegments.map(\.completionType) == [.dataPlayedBack])
    }

    @Test("seeking to duration while playing ends playback without scheduling an empty segment")
    func seekingToDurationWhilePlayingEndsPlayback() async throws {
        let url = try writePlaybackTestAudio(frameCount: 700)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        var didFinish = false
        engine.setFinishHandler { didFinish = true }
        try engine.load(url: url)
        driver.events.removeAll()
        try engine.play()

        engine.seek(to: engine.duration)

        #expect(driver.scheduledSegments.count == 1)
        #expect(driver.events == [.schedule, .start, .play, .stop])
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == engine.duration)
        #expect(didFinish)
    }

    @Test("zero length files finish without starting hardware playback")
    func zeroLengthFilesFinishWithoutStartingHardwarePlayback() async throws {
        let url = try writePlaybackTestAudio(frameCount: 0)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        var didFinish = false
        engine.setFinishHandler { didFinish = true }
        try engine.load(url: url)
        driver.events.removeAll()

        try engine.play()

        #expect(driver.events.isEmpty)
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0)
        #expect(engine.duration == 0)
        #expect(didFinish)
    }

    @Test("replay after natural completion resets the node sample clock")
    func replayAfterNaturalCompletionResetsNodeSampleClock() async throws {
        let url = try writePlaybackTestAudio(frameCount: 1_000)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        try engine.load(url: url)
        driver.events.removeAll()

        try engine.play()
        driver.renderedSampleTimeValue = 640
        driver.completeLatestSchedule()
        await Task.yield()

        #expect(!engine.isPlaying)
        #expect(engine.currentTime == engine.duration)
        #expect(driver.events == [.schedule, .start, .play, .stop])

        try engine.play()

        #expect(engine.isPlaying)
        #expect(engine.currentTime == 0)
        #expect(driver.scheduledSegments.map(\.startingFrame) == [0, 0])
        #expect(driver.events == [.schedule, .start, .play, .stop, .schedule, .play])
    }

    @Test("completion delivered after pause does not overwrite the paused position")
    func completionAfterPauseDoesNotOverwritePausedPosition() async throws {
        let url = try writePlaybackTestAudio(frameCount: 1_000)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        var finishCount = 0
        engine.setFinishHandler { finishCount += 1 }
        try engine.load(url: url)
        driver.events.removeAll()

        try engine.play()
        driver.renderedSampleTimeValue = 250
        engine.pause()
        driver.completeLatestSchedule()
        await Task.yield()

        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 250.0 / 44_100.0)
        #expect(finishCount == 0)
    }
}

@MainActor
private final class PlaybackEngineTestDriver: PlaybackSchedulingDriver {
    struct ScheduledSegment: Equatable {
        let startingFrame: AVAudioFramePosition
        let frameCount: AVAudioFrameCount
        let completionType: AVAudioPlayerNodeCompletionCallbackType
    }

    enum Event: Equatable {
        case schedule
        case start
        case play
        case pause
        case stop
    }

    var isRunning = false
    var renderedSampleTimeValue: AVAudioFramePosition?
    var scheduledSegments: [ScheduledSegment] = []
    var completionHandlers: [@Sendable () -> Void] = []
    var events: [Event] = []

    func prepare() {}

    func start() throws {
        isRunning = true
        events.append(.start)
    }

    func play() {
        events.append(.play)
    }

    func pause() {
        events.append(.pause)
    }

    func stop() {
        renderedSampleTimeValue = nil
        events.append(.stop)
    }

    func scheduleSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        _ = file
        scheduledSegments.append(
            ScheduledSegment(
                startingFrame: startingFrame,
                frameCount: frameCount,
                completionType: completionType
            )
        )
        completionHandlers.append(completionHandler)
        events.append(.schedule)
    }

    func completeLatestSchedule() {
        completionHandlers.last?()
    }

    func renderedSampleTime() -> AVAudioFramePosition? {
        renderedSampleTimeValue
    }
}

private func writePlaybackTestAudio(frameCount: AVAudioFrameCount) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PlaybackEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "audio.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let samples = buffer.floatChannelData?[0] {
        for frame in 0..<Int(frameCount) {
            samples[frame] = sin(Float(frame) * 0.01) * 0.2
        }
    }
    try file.write(from: buffer)
    return url
}
