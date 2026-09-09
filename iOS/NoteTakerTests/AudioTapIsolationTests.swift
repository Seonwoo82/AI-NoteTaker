import AVFoundation
import Foundation
import Testing
#if canImport(AudioPipeline)
import AudioPipeline
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Audio tap callback isolation")
struct AudioTapIsolationTests {
    @Test("enrollment tap created by UI can run on the audio worker thread")
    func enrollmentCallbackAcceptsBackgroundDelivery() async throws {
        let samples = TapSampleCollector()
        let callback = TapCallbackBox(VoiceEnrollmentCapture.makeTapHandler(handler: samples.append))
        let ranOnMain = try await Task.detached { try deliverTap(callback, channels: 2) }.value
        #expect(!ranOnMain)
        let chunks = samples.values()
        #expect(chunks.count == 1)
        #expect(chunks.first?.samples == Array(repeating: Float(0.5), count: 160))
        #expect(chunks.first?.sampleRate == 16_000)
    }

    #if os(iOS)
    @Test("observed recording tap created by UI writes audio from its worker thread")
    func recordingCallbackAcceptsBackgroundDelivery() async throws {
        let samples = TapSampleCollector()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let url = FileManager.default.temporaryDirectory.appending(path: "tap-isolation-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let worker = ObservedVoiceAudioWorker(audioFile: file, sampleRate: 16_000,
            liveAudioHandler: samples.append, failureHandler: {})
        let callback = TapCallbackBox(ObservedVoiceRecordingSession.makeTapHandler(worker: worker))
        let ranOnMain = try await Task.detached { try deliverTap(callback, channels: 1) }.value
        #expect(!ranOnMain)
        #expect(try worker.finish() == 160)
        #expect(try AVAudioFile(forReading: url).length == 160)
        #expect(samples.values().first?.samples == Array(repeating: Float(0.25), count: 160))
    }
    #endif
}

// AVFAudio invokes its block from its audio queue. This test transfers that same
// Objective-C block to a background task, without opening a microphone.
nonisolated private struct TapCallbackBox: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    init(_ block: @escaping AVAudioNodeTapBlock) { self.block = block }
}

nonisolated private final class TapSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [LiveAudioSamples] = []
    func append(_ chunk: LiveAudioSamples) { lock.withLock { chunks.append(chunk) } }
    func values() -> [LiveAudioSamples] { lock.withLock { chunks } }
}

nonisolated private func makeTapBuffer(channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    buffer.frameLength = 160
    let data = try #require(buffer.floatChannelData)
    for frame in 0..<160 {
        data[0][frame] = 0.25
        if channels > 1 { data[1][frame] = 0.75 }
    }
    return buffer
}

nonisolated private func deliverTap(_ callback: TapCallbackBox, channels: AVAudioChannelCount) throws -> Bool {
    callback.block(try makeTapBuffer(channels: channels), AVAudioTime(sampleTime: 0, atRate: 16_000))
    return Thread.isMainThread
}
