@preconcurrency import AVFAudio
import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Test("UI testing services use a fake recorder with deterministic transitions")
func uiTestingRecorderTransitionsWithoutTCC() async throws {
    let services = AppServices.uiTesting()
    let recorder = services.recorder

    #expect(recorder.state == .idle)

    let id = UUID()
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerFakeRecorderTests-\(id.uuidString)", directoryHint: .isDirectory)
        .appending(path: id.uuidString, directoryHint: .isDirectory)
    let start = try await recorder.start(RecorderRequest(
        id: id,
        directoryURL: directory,
        mode: .micAndSystem,
        microphoneUID: nil,
        microphoneGain: 1,
        systemGain: 1
    ))
    #expect(recorder.state == .recording)
    #expect(start.warnings == [])

    let preview = try await recorder.pause()
    #expect(recorder.state == .paused)
    #expect(preview.duration > 0)

    try await recorder.resume()
    #expect(recorder.state == .recording)

    let result = try await recorder.stop()
    #expect(recorder.state == .stopped)
    #expect(result.url.lastPathComponent == "audio.m4a")
    #expect(FileManager.default.fileExists(atPath: result.url.path))
    let audioFile = try AVAudioFile(forReading: result.url)
    #expect(audioFile.processingFormat.sampleRate == 48_000)
    #expect(audioFile.processingFormat.channelCount == 2)
}
