import Foundation

@MainActor
enum RecorderState: Equatable {
    case idle
    case recording
    case paused
    case stopped
}

@MainActor
protocol RecorderEngine: AnyObject {
    var state: RecorderState { get }
    var liveAudioHandler: LiveAudioSampleHandler? { get set }

    func supportsLiveAudioObservation(for mode: CaptureMode) -> Bool
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
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
    func stop() async
}

protocol PeakExtractor: Sendable {
    func peaks() async throws -> [Float]
}

protocol Trimmer: Sendable {
    func trim() async throws
}
