import AVFoundation
import Foundation
import Testing
@testable import NoteTakerIOS

@MainActor
@Suite("Playback audio-session ownership")
struct VoicePlayerSessionTests {
    private let recording = Recording(title: "Session ownership fixture", duration: 60, mode: .micOnly)
    private let url = URL(filePath: "/tmp/playback-session-fixture.m4a")

    @Test("stopping an idle playback engine never deactivates another audio owner")
    func idleStopDoesNotDeactivateSession() throws {
        let audio = try PlaybackSessionSpy()
        let engine = audio.engine()
        audio.owner = "recording"
        engine.stop()
        #expect(audio.deactivations == 0)
        #expect(audio.owner == "recording")
    }

    @Test("pause and resume retain position while stop releases ownership exactly once")
    func pauseResumeAndRepeatedStop() throws {
        let audio = try PlaybackSessionSpy()
        let engine = audio.engine()
        try engine.play(recording: recording, url: url)
        engine.seek(to: 12)
        engine.pause()
        #expect(audio.deactivations == 0)
        #expect(engine.currentTime == 12)
        try engine.play(recording: recording, url: url)
        #expect(audio.playerCreations == 1)
        #expect(engine.currentTime == 12)
        #expect(engine.isPlaying)
        engine.stop()
        #expect(engine.playbackToken == nil)
        #expect(audio.player.delegate == nil)
        #expect(audio.deactivations == 1)
        audio.owner = "recording"
        engine.stop()
        #expect(audio.deactivations == 1)
        #expect(audio.owner == "recording")
    }

    @Test("queued player callbacks after stop cannot deactivate recording", arguments: [true, false])
    func queuedCallbacksCannotAffectNewOwner(_ completed: Bool) async throws {
        let audio = try PlaybackSessionSpy()
        let engine = audio.engine()
        engine.finishHandler = { _, _ in audio.completions += 1 }
        try engine.play(recording: recording, url: url)
        if completed {
            engine.audioPlayerDidFinishPlaying(audio.player, successfully: true)
        } else {
            engine.audioPlayerDecodeErrorDidOccur(audio.player, error: nil)
        }
        engine.stop()
        audio.owner = "recording"
        try await Task.sleep(for: .milliseconds(10))
        #expect(audio.deactivations == 1)
        #expect(audio.completions == 0)
        #expect(audio.owner == "recording")
    }

    @Test("play failure releases an acquired session and later stop does not release another owner")
    func failedPlaybackReleasesOnlyItsSession() throws {
        let audio = try PlaybackSessionSpy()
        audio.player.shouldPlay = false
        let engine = audio.engine()
        #expect(throws: VoicePlayerError.playbackCouldNotStart) {
            try engine.play(recording: recording, url: url)
        }
        #expect(audio.deactivations == 1)
        audio.owner = "recording"
        engine.stop()
        #expect(audio.deactivations == 1)
        #expect(audio.owner == "recording")
    }

    @Test("failed session activation never gains permission to deactivate another owner")
    func failedActivationDoesNotClaimSession() throws {
        let audio = try PlaybackSessionSpy()
        audio.activationFails = true
        audio.owner = "recording"
        let engine = audio.engine()
        #expect(throws: PlaybackSessionFailure.activation) {
            try engine.play(recording: recording, url: url)
        }
        engine.stop()
        #expect(audio.playerCreations == 0)
        #expect(audio.deactivations == 0)
        #expect(audio.owner == "recording")
    }

    @Test("natural completion releases ownership before later idle stops")
    func completedPlaybackReleasesOnce() async throws {
        let audio = try PlaybackSessionSpy()
        let engine = audio.engine()
        engine.finishHandler = { _, _ in audio.completions += 1 }
        try engine.play(recording: recording, url: url)
        engine.audioPlayerDidFinishPlaying(audio.player, successfully: true)
        try await Task.sleep(for: .milliseconds(10))
        #expect(audio.completions == 1)
        #expect(audio.deactivations == 1)
        audio.owner = "recording"
        engine.stop()
        #expect(audio.owner == "recording")
        #expect(audio.deactivations == 1)
    }
}

private enum PlaybackSessionFailure: Error { case activation }

@MainActor
private final class PlaybackSessionSpy {
    let player: PlaybackAudioPlayerStub
    var owner: String?
    var deactivations = 0
    var playerCreations = 0
    var completions = 0
    var activationFails = false

    init() throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(356))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(320))
        data.append(Data(repeating: 0, count: 320))
        player = try PlaybackAudioPlayerStub(data: data)
    }

    func engine() -> AVFoundationPlaybackEngine {
        AVFoundationPlaybackEngine(makePlayer: { [self] url in
            playerCreations += 1
            player.stubURL = url
            return player
        }, activateAudioSession: { [self] in
            if activationFails { throw PlaybackSessionFailure.activation }
            owner = "playback"
        }, deactivateAudioSession: { [self] in
            deactivations += 1
            owner = nil
        })
    }
}

private final class PlaybackAudioPlayerStub: AVAudioPlayer {
    var stubURL: URL?
    var shouldPlay = true
    private var stubIsPlaying = false
    private var position: TimeInterval = 0
    private weak var storedDelegate: (any AVAudioPlayerDelegate)?
    override var url: URL? { stubURL }
    override var duration: TimeInterval { 60 }
    override var isPlaying: Bool { stubIsPlaying }
    override var currentTime: TimeInterval {
        get { position }
        set { position = newValue }
    }
    override var delegate: (any AVAudioPlayerDelegate)? {
        get { storedDelegate }
        set { storedDelegate = newValue }
    }
    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool { stubIsPlaying = shouldPlay; return shouldPlay }
    override func pause() { stubIsPlaying = false }
    override func stop() { stubIsPlaying = false }
}
