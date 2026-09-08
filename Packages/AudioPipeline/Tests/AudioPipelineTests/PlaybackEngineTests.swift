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

    @Test("loading a file configures playback with the source processing format")
    func loadConfiguresPlaybackWithSourceProcessingFormat() throws {
        let url = try writePlaybackTestAudio(frameCount: 500, sampleRate: 48_000, channelCount: 2)
        let file = try AVAudioFile(forReading: url)
        let driver = PlaybackEngineTestDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)

        try engine.load(url: url)

        #expect(driver.configuredFormats.map(\.sampleRate) == [file.processingFormat.sampleRate])
        #expect(driver.configuredFormats.map(\.channelCount) == [file.processingFormat.channelCount])
    }

    @Test("real AVAudio driver renders nonzero source audio offline")
    func realAVAudioDriverRendersNonzeroSourceAudioOffline() throws {
        let url = try writePlaybackTestAudio(frameCount: 4_410, sampleRate: 44_100, channelCount: 1)
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let driver = AVAudioPlaybackSchedulingDriver()
        let engine = PlaybackEngine(schedulingDriver: driver)
        try driver.engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 512)
        try engine.load(url: url)

        try engine.play()
        let rendered = try renderOfflineAudio(from: driver.engine, targetFrameCount: 4_800)

        #expect(driver.engine.manualRenderingFormat.sampleRate == 48_000)
        #expect(driver.engine.manualRenderingFormat.channelCount == 2)
        #expect(rendered.frameCount > 0)
        #expect(rendered.rootMeanSquare > 0.01)
        #expect(rendered.peak > 0.05)
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
    var configuredFormats: [AVAudioFormat] = []
    var scheduledSegments: [ScheduledSegment] = []
    var completionHandlers: [@Sendable () -> Void] = []
    var events: [Event] = []

    func prepare() {}

    func configureOutput(format: AVAudioFormat) {
        configuredFormats.append(format)
    }

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

private func writePlaybackTestAudio(
    frameCount: AVAudioFrameCount,
    sampleRate: Double = 44_100,
    channelCount: AVAudioChannelCount = 1
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PlaybackEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "audio.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let channelData = buffer.floatChannelData {
        for channel in 0..<Int(channelCount) {
            let samples = channelData[channel]
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.01) * 0.2
            }
        }
    }
    try file.write(from: buffer)
    return url
}

private struct RenderedAudio {
    let frameCount: Int
    let rootMeanSquare: Float
    let peak: Float
}

@MainActor
private func renderOfflineAudio(from engine: AVAudioEngine, targetFrameCount: Int) throws -> RenderedAudio {
    let buffer = AVAudioPCMBuffer(
        pcmFormat: engine.manualRenderingFormat,
        frameCapacity: engine.manualRenderingMaximumFrameCount
    )!
    var frameCount = 0
    var squareSum: Double = 0
    var sampleCount = 0
    var peak: Float = 0

    while frameCount < targetFrameCount {
        let framesToRender = min(
            engine.manualRenderingMaximumFrameCount,
            AVAudioFrameCount(targetFrameCount - frameCount)
        )
        let status = try engine.renderOffline(framesToRender, to: buffer)
        switch status {
        case .success:
            let frames = Int(buffer.frameLength)
            frameCount += frames
            guard let channels = buffer.floatChannelData else { continue }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames {
                    let sample = channels[channel][frame]
                    peak = max(peak, abs(sample))
                    squareSum += Double(sample * sample)
                    sampleCount += 1
                }
            }
        case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
            continue
        case .error:
            throw PlaybackOfflineRenderError.renderFailed
        @unknown default:
            throw PlaybackOfflineRenderError.renderFailed
        }
    }

    let rms = sampleCount == 0 ? 0 : Float((squareSum / Double(sampleCount)).squareRoot())
    return RenderedAudio(frameCount: frameCount, rootMeanSquare: rms, peak: peak)
}

private enum PlaybackOfflineRenderError: Error {
    case renderFailed
}
