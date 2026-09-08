import Foundation
import AudioPipeline

@MainActor
enum RecorderState: Equatable {
    case idle
    case recording
    case paused
    case stopped
}

nonisolated struct RecorderRequest: Sendable {
    let id: UUID
    let directoryURL: URL
    let mode: CaptureMode
    let microphoneUID: String?
    let microphoneGain: Float
    let systemGain: Float
}

nonisolated struct RecorderStart: Sendable {
    let warnings: [String]
}

nonisolated struct RecorderPreview: Sendable {
    let url: URL
    let duration: TimeInterval
}

nonisolated struct RecorderResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let warnings: [String]
}

nonisolated enum RecorderEvent: Equatable, Sendable {
    case recordingFailed(recordingID: UUID, message: String, settingsURL: URL?, keepsPartialFile: Bool)
    case levels(recordingID: UUID, progress: CaptureProgress)
}

nonisolated enum RecorderEngineError: Error, Equatable, Sendable {
    case pauseUnavailable
    case permissionDenied(message: String, settingsURL: URL?)
    case failed(message: String, settingsURL: URL?, keepsPartialFile: Bool)

    var message: String {
        switch self {
        case .pauseUnavailable:
            return "Pause is not available for this recording engine yet."
        case .permissionDenied(let message, _),
             .failed(let message, _, _):
            return message
        }
    }

    var settingsURL: URL? {
        switch self {
        case .pauseUnavailable:
            return nil
        case .permissionDenied(_, let settingsURL),
             .failed(_, let settingsURL, _):
            return settingsURL
        }
    }

    var keepsPartialFile: Bool {
        switch self {
        case .pauseUnavailable,
             .permissionDenied:
            return false
        case .failed(_, _, let keepsPartialFile):
            return keepsPartialFile
        }
    }
}

@MainActor
protocol RecorderEngine: AnyObject {
    var state: RecorderState { get }
    var events: AsyncStream<RecorderEvent> { get }
    var liveAudioHandler: LiveAudioSampleHandler? { get set }

    func supportsLiveAudioObservation(for mode: CaptureMode) -> Bool
    func start(_ request: RecorderRequest) async throws -> RecorderStart
    func pause() async throws -> RecorderPreview
    func resume() async throws
    func stop() async throws -> RecorderResult
    func confirmPublished() async
}

extension RecorderEngine {
    var liveAudioHandler: LiveAudioSampleHandler? {
        get { nil }
        set {}
    }

    func supportsLiveAudioObservation(for mode: CaptureMode) -> Bool {
        false
    }
}

@MainActor
protocol PlayerEngine: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?)
    func load(url: URL) async throws
    func play() async throws
    func pause() async
    func seek(to time: TimeInterval) async
    func stop() async
}

nonisolated enum PlayerEngineError: Error, Equatable, Sendable {
    case failed(String)

    var message: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
