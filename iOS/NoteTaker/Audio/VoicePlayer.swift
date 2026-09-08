import AVFoundation
import Foundation
import Observation

@MainActor
protocol VoicePlaybackEngine: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var playbackToken: ObjectIdentifier? { get }
    var finishHandler: (@MainActor @Sendable (Bool, ObjectIdentifier) -> Void)? { get set }

    func play(recording: Recording, url: URL) throws
    func pause()
    func stop()
    func seek(to time: TimeInterval)
}

@MainActor
@Observable
final class VoicePlayer {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var recordingID: UUID?
    var errorMessage: String?

    @ObservationIgnored private let engine: any VoicePlaybackEngine
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var activePlaybackToken: ObjectIdentifier?

    init(engine: any VoicePlaybackEngine = AVFoundationPlaybackEngine()) {
        self.engine = engine
        self.engine.finishHandler = { [weak self] finishedSuccessfully, token in
            self?.playbackFinished(successfully: finishedSuccessfully, token: token)
        }
    }

    func play(recording: Recording, url: URL) throws {
        errorMessage = nil

        if recordingID == recording.id, isPlaying {
            pause()
            return
        }

        do {
            try engine.play(recording: recording, url: url)
            activePlaybackToken = engine.playbackToken
            recordingID = recording.id
            duration = engine.duration > 0 ? engine.duration : recording.duration
            currentTime = engine.currentTime
            isPlaying = engine.isPlaying
            startProgressClock()
        } catch {
            errorMessage = describe(error)
            throw error
        }
    }

    func pause() {
        engine.pause()
        isPlaying = engine.isPlaying
        currentTime = engine.currentTime
        stopProgressClock()
    }

    func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
        recordingID = nil
        activePlaybackToken = nil
        stopProgressClock()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        engine.seek(to: clamped)
        currentTime = engine.currentTime
    }

    private func startProgressClock() {
        stopProgressClock()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    self.currentTime = self.engine.currentTime
                    self.duration = self.engine.duration
                    self.isPlaying = self.engine.isPlaying
                    if !self.engine.isPlaying {
                        self.stopProgressClock()
                    }
                }
            }
        }
    }

    private func stopProgressClock() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func playbackFinished(successfully: Bool, token: ObjectIdentifier) {
        guard activePlaybackToken == token else { return }
        isPlaying = false
        currentTime = successfully ? duration : engine.currentTime
        stopProgressClock()
        if !successfully {
            errorMessage = VoicePlayerError.decodeFailed.errorDescription
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

nonisolated enum VoicePlayerError: Error, LocalizedError, Sendable {
    case playbackCouldNotStart
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .playbackCouldNotStart:
            return String(localized: "The recording could not be played.")
        case .decodeFailed:
            return String(localized: "The recording stopped because the audio could not be decoded.")
        }
    }
}

@MainActor
private final class AVFoundationPlaybackEngine: NSObject, VoicePlaybackEngine, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var finishHandler: (@MainActor @Sendable (Bool, ObjectIdentifier) -> Void)?

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var duration: TimeInterval {
        player?.duration ?? 0
    }

    var playbackToken: ObjectIdentifier? {
        player.map(ObjectIdentifier.init)
    }

    func play(recording: Recording, url: URL) throws {
        var shouldDeactivateSession = false
        defer {
            if shouldDeactivateSession {
                deactivateSession()
            }
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        shouldDeactivateSession = true
        #endif

        if player?.url == url {
            if let player, player.currentTime >= player.duration {
                player.currentTime = 0
            }
            guard player?.play() == true else {
                throw VoicePlayerError.playbackCouldNotStart
            }
            shouldDeactivateSession = false
            return
        }

        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        guard newPlayer.play() else {
            throw VoicePlayerError.playbackCouldNotStart
        }
        player = newPlayer
        shouldDeactivateSession = false
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let token = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard self?.playbackToken == token else { return }
            self?.deactivateSession()
            self?.finishHandler?(flag, token)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let token = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard self?.playbackToken == token else { return }
            self?.deactivateSession()
            self?.finishHandler?(false, token)
        }
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
