import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
struct MeetingPlaybackTests {
    @Test("owner playback merges overlapping selections and keeps other speech gaps")
    func ranges() throws {
        let turns = [turn("b", 8, 10), turn("a", 1, 3), turn("c", 2, 4)]
        #expect(try MeetingPlaybackInterval.make(from: turns) == [MeetingPlaybackInterval(start: 1, end: 4), MeetingPlaybackInterval(start: 8, end: 10)])
        #expect(throws: AIError.self) { try MeetingPlaybackInterval.make(from: [turn("bad", .nan, 2)]) }
    }

    @Test("playback advances across selected utterances and pauses at the last boundary")
    func playsSelectedTurns() async throws {
        let player = PlaybackProbe()
        let controller = MeetingSegmentPlayback(position: { player.time }, isPlaying: { player.playing },
            playAt: { _, time in player.time = time; player.playing = true },
            seek: { _, time in player.time = time; player.seeks.append(time) },
            pause: { _ in player.playing = false },
            stop: { _ in player.playing = false })
        defer { controller.cancel() }
        await controller.play(turns: [turn("a", 1, 2), turn("b", 6, 7)])
        #expect(player.time == 1)
        player.time = 2
        try await Task.sleep(for: .milliseconds(90))
        #expect(player.seeks == [6])
        player.time = 7
        try await Task.sleep(for: .milliseconds(90))
        #expect(!player.playing && !controller.isActive)
    }


    @Test("segment stop pauses active owned playback")
    func stopPausesActiveOwnedPlayback() async throws {
        let player = PlaybackProbe()
        var stoppedTokens: [UUID] = []
        let controller = MeetingSegmentPlayback(position: { player.time }, isPlaying: { player.playing },
            playAt: { _, time in player.time = time; player.playing = true },
            seek: { _, time in player.time = time },
            pause: { _ in player.playing = false },
            stop: { token in stoppedTokens.append(token); player.playing = false })

        await controller.play(turns: [turn("a", 1, 2)])
        #expect(player.playing)

        await controller.stop()

        #expect(!player.playing)
        #expect(!controller.isActive)
        #expect(stoppedTokens.count == 1)
    }

    @Test("segment stop during pending start prevents late audio")
    func stopDuringPendingStartPreventsLateAudio() async throws {
        let player = PlaybackProbe()
        final class StartGate {
            var continuation: CheckedContinuation<Void, Never>?
        }
        let gate = StartGate()
        let controller = MeetingSegmentPlayback(position: { player.time }, isPlaying: { player.playing },
            playAt: { _, time in
                player.time = time
                await withCheckedContinuation { gate.continuation = $0 }
                player.playing = true
            },
            seek: { _, time in player.time = time },
            pause: { _ in player.playing = false },
            stop: { _ in player.playing = false })

        let playTask = Task { await controller.play(turns: [turn("a", 1, 2)]) }
        for _ in 0..<1000 {
            if gate.continuation != nil { break }
            await Task.yield()
        }
        await controller.stop()
        gate.continuation?.resume()
        await playTask.value

        #expect(!player.playing)
        #expect(!controller.isActive)
    }

    @Test("stale segment stop does not interrupt newer owner playback")
    func staleStopDoesNotInterruptNewOwnerPlayback() async throws {
        let player = PlaybackProbe()
        final class StartGate {
            var continuation: CheckedContinuation<Void, Never>?
        }
        let gate = StartGate()
        var activeOwner: UUID?
        var pendingOwner: UUID?
        var pendingStart = true
        let controller = MeetingSegmentPlayback(position: { player.time }, isPlaying: { player.playing },
            playAt: { owner, time in
                if pendingStart {
                    pendingStart = false
                    pendingOwner = owner
                    player.time = time
                    await withCheckedContinuation { gate.continuation = $0 }
                    player.playing = true
                    return
                }
                activeOwner = owner
                player.time = time
                player.playing = true
            },
            seek: { owner, time in
                guard activeOwner == owner else { return }
                player.time = time
            },
            pause: { owner in
                guard activeOwner == owner else { return }
                player.playing = false
            },
            stop: { owner in
                guard activeOwner == owner else { return }
                player.playing = false
            })

        let firstPlay = Task { await controller.play(turns: [turn("a", 1, 2)]) }
        for _ in 0..<1000 {
            if pendingOwner != nil { break }
            await Task.yield()
        }
        await controller.stop()
        await controller.play(turns: [turn("b", 3, 4)])
        let newOwner = try #require(activeOwner)
        #expect(player.playing)

        gate.continuation?.resume()
        await firstPlay.value

        #expect(activeOwner == newOwner)
        #expect(player.playing)
    }

    @Test("denied or cancelled voice enrollment never starts the microphone")
    func enrollmentPermissionCancellation() async throws {
        let denied = VoiceEnrollmentCapture(requestPermission: { false })
        await #expect(throws: AIError.self) { try await denied.start { _ in } }
        #expect(!denied.isRunning)
        var permission: CheckedContinuation<Bool, Never>?
        let capture = VoiceEnrollmentCapture(requestPermission: { await withCheckedContinuation { permission = $0 } })
        let task = Task { try await capture.start { _ in } }
        for _ in 0..<1000 { if permission != nil { break }; await Task.yield() }
        let resume = try #require(permission)
        capture.stop()
        resume.resume(returning: true)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!capture.isRunning)
    }

    private func turn(_ id: String, _ start: Double, _ end: Double) -> TranscriptTurn {
        TranscriptTurn(id: id, start: start, end: end, speakerID: "owner", text: "sample")
    }
}

@MainActor
private final class PlaybackProbe {
    var time: Double = 0
    var playing = false
    var seeks: [Double] = []
}
