import Foundation

public struct RecordingConfiguration: Sendable {
    public let mode: CaptureMode
    public let microphoneUID: String?
    public let outputURL: URL
    public let microphoneGain: Float
    public let systemGain: Float
    public let clockSource: AggregateClockSource
    public let liveAudioHandler: LiveAudioSampleHandler?

    public init(
        mode: CaptureMode,
        microphoneUID: String?,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        clockSource: AggregateClockSource = .microphone,
        liveAudioHandler: LiveAudioSampleHandler? = nil
    ) {
        self.mode = mode
        self.microphoneUID = microphoneUID
        self.outputURL = outputURL
        self.microphoneGain = microphoneGain
        self.systemGain = systemGain
        self.clockSource = clockSource
        self.liveAudioHandler = liveAudioHandler
    }
}

public struct CaptureStartResult: Sendable {
    public let aggregateSampleRate: Double
    public let channelMap: InputChannelMap
    public let warnings: [AudioCaptureWarning]

    public init(
        aggregateSampleRate: Double,
        channelMap: InputChannelMap,
        warnings: [AudioCaptureWarning] = []
    ) {
        self.aggregateSampleRate = aggregateSampleRate
        self.channelMap = channelMap
        self.warnings = warnings
    }
}
