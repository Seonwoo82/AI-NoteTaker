import Foundation

@MainActor
final class FakeRecorderEngine: RecorderEngine {
    private(set) var state: RecorderState = .idle

    func start() async throws {
        state = .recording
    }

    func pause() async throws {
        state = .paused
    }

    func resume() async throws {
        state = .recording
    }

    func stop() async throws {
        state = .stopped
    }
}

@MainActor
final class FakePlayerEngine: PlayerEngine {
    func stop() async {}
}

struct FakePeakExtractor: PeakExtractor {
    func peaks() async throws -> [Float] {
        []
    }
}

struct FakeTrimmer: Trimmer {
    func trim() async throws {}
}
