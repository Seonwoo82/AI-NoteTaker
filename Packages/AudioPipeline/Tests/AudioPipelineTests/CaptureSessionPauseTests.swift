@testable import AudioPipeline
import Foundation
import Testing

@Test("CaptureSession pause and resume keep capture resources alive")
func captureSessionPauseAndResumeKeepCaptureResourcesAlive() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(log: log))
    let output = try temporaryCaptureURL()

    _ = try await session.start(configuration: RecordingConfiguration(
        mode: .micOnly,
        microphoneUID: nil,
        outputURL: output.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1
    ))

    let segment = try await session.pause()
    try await session.resume(outputURL: output.appendingPathComponent("001.m4a"))

    #expect(segment.duration == 0.25)
    let eventsBeforeStop = log.events()
    #expect(eventsBeforeStop.contains(.writerPause))
    #expect(eventsBeforeStop.contains(.writerResume))
    #expect(!eventsBeforeStop.contains(.listenerRemove))
    #expect(!eventsBeforeStop.contains(.deviceStop))
    #expect(!eventsBeforeStop.contains(.ioProcDestroy))
    #expect(!eventsBeforeStop.contains(.aggregateDestroy))
    #expect(!eventsBeforeStop.contains(.tapDestroy))

    _ = try await session.stop()
}

private func temporaryCaptureURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
