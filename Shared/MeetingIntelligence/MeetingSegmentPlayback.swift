import Foundation
import Observation

nonisolated struct MeetingPlaybackInterval: Equatable, Sendable {
    let start: Double
    let end: Double

    static func make(from turns: [TranscriptTurn]) throws -> [Self] {
        var result: [Self] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            guard turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start else {
                throw AIError(message: "재생할 발화 구간이 올바르지 않아요.")
            }
            if let last = result.last, turn.start <= last.end + 0.05 {
                result[result.count - 1] = Self(start: last.start, end: max(last.end, turn.end))
            } else { result.append(Self(start: turn.start, end: turn.end)) }
        }
        return result
    }
}

@MainActor
@Observable
final class MeetingSegmentPlayback {
    private(set) var isActive = false
    private(set) var error: String?
    private let position: () -> Double
    private let isPlaying: () -> Bool
    private let playAt: (UUID, Double) async throws -> Void
    private let seek: (UUID, Double) async -> Void
    private let pause: (UUID) async -> Void
    private let stopPlayback: (UUID) async -> Void
    private var monitor: Task<Void, Never>?
    private var token = UUID()

    init(position: @escaping () -> Double, isPlaying: @escaping () -> Bool,
         playAt: @escaping (UUID, Double) async throws -> Void, seek: @escaping (UUID, Double) async -> Void,
         pause: @escaping (UUID) async -> Void, stop: @escaping (UUID) async -> Void) {
        self.position = position; self.isPlaying = isPlaying
        self.playAt = playAt; self.seek = seek; self.pause = pause; self.stopPlayback = stop
    }

    isolated deinit { cancel() }

    func play(turns: [TranscriptTurn]) async {
        cancel()
        error = nil
        let current = nextToken()
        do {
            let intervals = try MeetingPlaybackInterval.make(from: turns)
            guard let first = intervals.first else { return }
            try await playAt(current, first.start)
            guard token == current else {
                await stopPlayback(current)
                return
            }
            isActive = true
            monitor = Task { [weak self] in
                var index = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard let self, self.token == current, !Task.isCancelled else { return }
                    guard self.isPlaying() else { self.cancel(); return }
                    let time = self.position()
                    guard time.isFinite else { self.cancel(); return }
                    let range = intervals[index]
                    // An external seek leaves the user's transport in control.
                    if time < range.start - 0.15 || time > range.end + 0.75 {
                        self.cancel(); return
                    }
                    if time >= range.end {
                        index += 1
                        if index == intervals.count {
                            await self.pause(current)
                            if self.token == current { self.cancel() }
                            return
                        }
                        await self.seek(current, intervals[index].start)
                    }
                }
            }
        } catch is CancellationError {
            if token == current { cancel() }
        } catch { self.error = "발화 구간을 재생하지 못했어요. 녹음 파일을 확인해 주세요." }
    }

    func cancel() {
        token = UUID()
        monitor?.cancel()
        monitor = nil
        isActive = false
    }

    func stop() async {
        let current = token
        cancel()
        await stopPlayback(current)
    }

    private func nextToken() -> UUID {
        token = UUID()
        return token
    }
}
