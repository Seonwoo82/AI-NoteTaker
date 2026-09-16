import AVFoundation
import XCTest
@testable import NoteTakerIOS

/// Explicit physical-device diagnostic; never enabled by the normal test suite.
@MainActor
final class RecordingHardwareTests: XCTestCase {
    func testObservedMicrophoneStaysRunningAndWritesAudio() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical microphone is required.")
        #else
        guard ProcessInfo.processInfo.environment["NOTETAKER_RECORDING_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Physical microphone capture is opt-in.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "RecordingHardware-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let recorder = VoiceRecorder()
        let samples = HardwareSampleCounter()
        recorder.liveAudioHandler = { samples.add($0.samples.count) }
        let events = HardwareEventLog()
        let route = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil) { note in
            events.append("route:\(note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "unknown")")
        }
        let config = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: nil) { _ in events.append("engine-configuration") }
        let interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { note in
            events.append("interruption:\(note.userInfo?[AVAudioSessionInterruptionTypeKey] ?? "unknown")")
        }
        defer {
            for observer in [route, config, interruption] { NotificationCenter.default.removeObserver(observer) }
        }
        await recorder.start(library: store, mode: .micOnly)
        let beganRecording = recorder.isRecording
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(500))
            if !recorder.isRecording { break }
        }
        let remainedRecording = recorder.isRecording
        let saved = await recorder.finish(library: store)
        let diagnostic = "started=\(beganRecording), remained=\(remainedRecording), samples=\(samples.count), saved=\(saved?.duration ?? -1), records=\(store.recordings.count), error=\(recorder.errorMessage ?? "none"), events=\(events.values)"
        print("RECORDING_HARDWARE: \(diagnostic)")
        let attachment = XCTAttachment(string: diagnostic)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(beganRecording, diagnostic)
        XCTAssertTrue(remainedRecording, diagnostic)
        XCTAssertGreaterThan(samples.count, 0, diagnostic)
        let recording = try XCTUnwrap(saved, diagnostic)
        XCTAssertGreaterThan(recording.duration, 4, diagnostic)
        let file = try AVAudioFile(forReading: store.paths.directory(for: recording.id).appending(path: "audio.m4a"))
        XCTAssertGreaterThan(file.length, 0)
        #endif
    }
}

nonisolated private final class HardwareSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func add(_ value: Int) { lock.withLock { stored += value } }
}

nonisolated private final class HardwareEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}
