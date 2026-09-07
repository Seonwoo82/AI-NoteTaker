import AudioPipeline
import Foundation

@MainActor
final class AudioPipelinePlayerEngine: PlayerEngine {
    private let engine: PlaybackEngine

    var isPlaying: Bool { engine.isPlaying }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }

    init(engine: PlaybackEngine = PlaybackEngine()) {
        self.engine = engine
    }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        engine.setFinishHandler(handler)
    }

    func load(url: URL) async throws {
        try engine.load(url: url)
    }

    func play() async throws {
        try engine.play()
    }

    func pause() async {
        engine.pause()
    }

    func seek(to time: TimeInterval) async {
        engine.seek(to: time)
    }

    func stop() async {
        engine.stop()
    }
}
