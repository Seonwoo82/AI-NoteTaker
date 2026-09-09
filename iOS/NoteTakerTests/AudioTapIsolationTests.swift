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
    @Test("continuous hardware-sized tap buffers reach voice enrollment without a false gap", arguments: [16_000.0, 44_100.0, 48_000.0])
    func continuousTapReachesEnrollment(sampleRate: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tap-enrollment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingProfileStore(root: root)
        let manager = OwnerVoiceManager(profile: store, backend: TapSpeakerBackend(),
            policy: OwnerVoicePolicy())
        await manager.prepareModels()
        await manager.beginEnrollment()
        let callback = TapCallbackBox(VoiceEnrollmentCapture.makeTapHandler(handler: manager.audioHandler))
        let chunkCount = Int(ceil(12 * sampleRate / 4_096))
        for index in 0..<chunkCount {
            _ = try await Task.detached {
                try deliverTap(callback, channels: 1, frameCount: 4_096, sampleRate: sampleRate)
            }.value
            let expectedDuration = Double((index + 1) * 4_096) / sampleRate
            for _ in 0..<100 {
                if manager.presentation.elapsed >= expectedDuration - 1e-9 || manager.presentation.error != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(manager.presentation.error == nil)
            #expect(manager.presentation.isEnrolling)
        }
        await manager.finishEnrollment()
        let voice = try #require(store.localVoice)
        #expect(abs(voice.sampleDuration - Double(chunkCount * 4_096) / sampleRate) < 1e-9)
        #expect(manager.presentation.error == nil)
    }

    @Test("cancellation during microphone permission returns cancellation before capture setup")
    func taskCancellationDuringPermission() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        let capture = VoiceEnrollmentCapture(requestPermission: {
            await withCheckedContinuation { permission = $0 }
        })
        defer { capture.stop() }
        let start = Task { try await capture.start(handler: { _ in }) }
        for _ in 0..<100 {
            if permission != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let continuation = try #require(permission)
        start.cancel()
        // A denied result guarantees this regression never opens a real microphone.
        continuation.resume(returning: false)
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(!capture.isRunning)
    }

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

nonisolated private func makeTapBuffer(channels: AVAudioChannelCount, frameCount: AVAudioFrameCount, sampleRate: Double) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let data = try #require(buffer.floatChannelData)
    for frame in 0..<Int(frameCount) {
        data[0][frame] = 0.25
        if channels > 1 { data[1][frame] = 0.75 }
    }
    return buffer
}

nonisolated private func deliverTap(_ callback: TapCallbackBox, channels: AVAudioChannelCount,
    frameCount: AVAudioFrameCount = 160, sampleRate: Double = 16_000) throws -> Bool {
    callback.block(try makeTapBuffer(channels: channels, frameCount: frameCount, sampleRate: sampleRate),
        AVAudioTime(sampleTime: 0, atRate: sampleRate))
    return Thread.isMainThread
}

private actor TapSpeakerBackend: SpeakerAnalysisServing {
    nonisolated let embeddingModelID = "tap-fixture"
    func prepare() async throws {}
    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] { [1, 0, 0] }
    func diarize(audioURL: URL) async throws -> AcousticDiarization { AcousticDiarization(speakers: [], spans: []) }
}
