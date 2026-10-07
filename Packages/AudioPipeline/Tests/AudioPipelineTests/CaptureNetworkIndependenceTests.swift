@testable import AudioPipeline
import AVFAudio
import Dispatch
import Foundation
import Testing

@Test("Local AAC recording continues through network-related device-list changes", arguments: CaptureMode.allCases)
func captureRecordingSurvivesDeviceListChanges(mode: CaptureMode) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("network-changes.m4a")
    let log = LifecycleLog()
    let factory = LocalRecordingWriterFactory()
    let session = CaptureSession(dependencies: .fake(log: log, writerFactory: factory))
    _ = try await session.start(configuration: RecordingConfiguration(
        mode: mode,
        microphoneUID: "mic-uid",
        outputURL: outputURL,
        microphoneGain: 1,
        systemGain: 1
    ))
    let capture = try factory.requireCapture()
    defer { capture.writer.requestStop(); _ = try? capture.writer.join() }

    // Network transitions can add/remove unrelated AirPlay devices in the global list.
    try capture.appendTone(frequency: 440, frameCount: 12_000)
    let deadline = Date().addingTimeInterval(3)
    while (capture.writer.currentProgress?.duration ?? 0) < 0.25 && Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect((capture.writer.currentProgress?.duration ?? 0) >= 0.25)
    for _ in 0..<4 {
        await session.monitorEventReceived(.deviceListChanged, generation: 1)
    }
    #expect(!log.events().contains(.deviceStop))
    try capture.appendTone(frequency: 880, frameCount: 12_000)

    let output = try await session.stop()
    #expect(output.url == outputURL)
    #expect(output.stats.inputFramesRead == 24_000)
    #expect(output.stats.outputFramesWritten == 24_000)
    #expect(output.stats.ringDroppedFrames == 0)
    #expect(abs(output.duration - 0.5) < 0.000_001)

    // Decode the finalized file, not just writer counters, to verify both portions survived.
    let file = try AVAudioFile(forReading: outputURL)
    #expect(file.processingFormat.sampleRate == 48_000)
    #expect(file.length >= 24_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
    try file.read(into: buffer)
    try #require(buffer.frameLength >= 24_000)
    let samples = try #require(buffer.floatChannelData?[0])
    for range in [2_000..<10_000, 14_000..<22_000] {
        let energy = range.reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) }
        #expect(energy / Double(range.count) > 0.001)
    }
}

private final class LocalRecordingWriterFactory: CaptureSessionRecordingWriterMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: LocalRecordingCapture?

    func makeWriter(
        inputSampleRate: Double,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        liveAudioHandler: LiveAudioSampleHandler?,
        diskSpaceChecker: any DiskSpaceChecking
    ) throws -> any CaptureSessionRecordingWriter {
        let writer = try RecordingWriter(
            inputSampleRate: inputSampleRate,
            inputChannelCount: inputChannelCount,
            layout: layout,
            ring: ring,
            wake: wake,
            outputURL: outputURL,
            microphoneGain: microphoneGain,
            systemGain: systemGain,
            liveAudioHandler: liveAudioHandler,
            diskSpaceChecker: diskSpaceChecker
        )
        lock.lock()
        capture = LocalRecordingCapture(writer: writer, ring: ring, wake: wake,
                                        sampleRate: inputSampleRate, channelCount: inputChannelCount)
        lock.unlock()
        return writer
    }

    func requireCapture() throws -> LocalRecordingCapture {
        lock.lock()
        defer { lock.unlock() }
        return try #require(capture)
    }
}

private struct LocalRecordingCapture {
    let writer: RecordingWriter
    let ring: SPSCRingBuffer
    let wake: DispatchSemaphore
    let sampleRate: Double
    let channelCount: Int

    func appendTone(frequency: Double, frameCount: Int) throws {
        let samples = (0..<frameCount).flatMap { frame in
            Array(repeating: Float(0.2 * sin(2 * .pi * frequency * Double(frame) / sampleRate)), count: channelCount)
        }
        try #require(samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) } == frameCount)
        wake.signal()
    }
}
