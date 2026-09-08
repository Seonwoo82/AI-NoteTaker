import AVFAudio
import Foundation

@MainActor
public final class PlaybackEngine {
    public enum PlaybackError: Error, Equatable, Sendable {
        case noLoadedFile
    }

    private let schedulingDriver: PlaybackSchedulingDriver
    private var file: AVAudioFile?
    private var startingFrame: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var hasScheduledSegment = false
    private var finishHandler: (@MainActor () -> Void)?

    public private(set) var isPlaying = false

    public var currentTime: TimeInterval {
        guard let file else { return 0 }
        let frame = currentFrame(in: file)
        return seconds(for: frame, in: file)
    }

    public var duration: TimeInterval {
        guard let file else { return 0 }
        return seconds(for: file.length, in: file)
    }

    public init() {
        self.schedulingDriver = AVAudioPlaybackSchedulingDriver()
        schedulingDriver.prepare()
    }

    init(schedulingDriver: PlaybackSchedulingDriver) {
        self.schedulingDriver = schedulingDriver
        schedulingDriver.prepare()
    }

    public func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        finishHandler = handler
    }

    public func load(url: URL) throws {
        stop()
        clearLoadedFile()
        file = try AVAudioFile(forReading: url)
        if let file {
            schedulingDriver.configureOutput(format: file.processingFormat)
        }
        seekFrame = 0
    }

    public func play() throws {
        guard let file else { throw PlaybackError.noLoadedFile }
        if isPlaying { return }
        if file.length == 0 {
            finishPlayback(at: 0)
            return
        }
        if currentFrame(in: file) >= file.length {
            seekFrame = 0
        }

        generation += 1
        let playGeneration = generation
        startingFrame = seekFrame
        stopScheduledSegmentIfNeeded()
        schedule(from: startingFrame, generation: playGeneration)
        if !schedulingDriver.isRunning {
            try schedulingDriver.start()
        }
        schedulingDriver.play()
        isPlaying = true
    }

    public func pause() {
        guard let file else { return }
        seekFrame = currentFrame(in: file)
        generation += 1
        schedulingDriver.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        guard let file else { return }
        seekFrame = frame(for: PlaybackTimeline(duration: duration).clampedSeekTime(time), in: file)
        let wasPlaying = isPlaying
        generation += 1
        schedulingDriver.stop()
        hasScheduledSegment = false
        isPlaying = false
        guard wasPlaying else { return }
        guard seekFrame < file.length else {
            finishPlayback(at: file.length)
            return
        }
        let playGeneration = generation
        startingFrame = seekFrame
        schedule(from: startingFrame, generation: playGeneration)
        schedulingDriver.play()
        isPlaying = true
    }

    public func stop() {
        generation += 1
        schedulingDriver.stop()
        hasScheduledSegment = false
        isPlaying = false
        seekFrame = 0
    }

    private func clearLoadedFile() {
        file = nil
        startingFrame = 0
        seekFrame = 0
        hasScheduledSegment = false
    }

    private func schedule(from frame: AVAudioFramePosition, generation: Int) {
        guard let file else { return }
        let clampedFrame = min(max(0, frame), file.length)
        let frameCount = AVAudioFrameCount(max(0, file.length - clampedFrame))
        guard frameCount > 0 else {
            finishPlayback(at: file.length)
            return
        }
        schedulingDriver.scheduleSegment(
            file,
            startingFrame: clampedFrame,
            frameCount: frameCount,
            completionType: .dataPlayedBack
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.finishPlayback(at: file.length)
            }
        }
        hasScheduledSegment = true
    }

    private func currentFrame(in file: AVAudioFile) -> AVAudioFramePosition {
        guard isPlaying,
              let sampleTime = schedulingDriver.renderedSampleTime()
        else {
            return min(max(0, seekFrame), file.length)
        }
        return min(max(0, startingFrame + sampleTime), file.length)
    }

    private func finishPlayback(at frame: AVAudioFramePosition) {
        generation += 1
        let shouldStopScheduledSegment = hasScheduledSegment
        isPlaying = false
        seekFrame = frame
        hasScheduledSegment = false
        if shouldStopScheduledSegment {
            schedulingDriver.stop()
        }
        finishHandler?()
    }

    private func stopScheduledSegmentIfNeeded() {
        guard hasScheduledSegment else { return }
        schedulingDriver.stop()
        hasScheduledSegment = false
    }

    private func frame(for time: TimeInterval, in file: AVAudioFile) -> AVAudioFramePosition {
        AVAudioFramePosition((time * file.processingFormat.sampleRate).rounded(.towardZero))
    }

    private func seconds(for frame: AVAudioFramePosition, in file: AVAudioFile) -> TimeInterval {
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return TimeInterval(frame) / file.processingFormat.sampleRate
    }
}

@MainActor
protocol PlaybackSchedulingDriver: AnyObject {
    var isRunning: Bool { get }

    func prepare()
    func configureOutput(format: AVAudioFormat)
    func start() throws
    func play()
    func pause()
    func stop()
    func scheduleSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable () -> Void
    )
    func renderedSampleTime() -> AVAudioFramePosition?
}

@MainActor
final class AVAudioPlaybackSchedulingDriver: PlaybackSchedulingDriver {
    let engine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var isRunning: Bool {
        engine.isRunning
    }

    func prepare() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    func configureOutput(format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func play() {
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func stop() {
        playerNode.stop()
    }

    func scheduleSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: completionType,
            completionHandler: { _ in completionHandler() }
        )
    }

    func renderedSampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return nil
        }
        return AVAudioFramePosition(playerTime.sampleTime)
    }
}
