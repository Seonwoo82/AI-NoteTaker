import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Voice enrollment signal preparation")
struct VoiceEnrollmentSignalTests {
    @Test("pauses do not erase quiet audio activity and bounded gain avoids clipping")
    func quietInputWithSilentEdges() throws {
        let voice = (0..<192_000).map { Float(sin(Double($0) * 2 * .pi * 170 / 16_000)) * 0.004 }
        let samples = Array(repeating: Float(0), count: 32_000) + voice + Array(repeating: Float(0), count: 48_000)
        let signal = VoiceEnrollmentSignal.measure(samples, sampleRate: 16_000)
        #expect(signal.rms < 0.01)
        #expect(abs(signal.activeDuration - 12) < 0.03)
        let prepared = try VoiceEnrollmentSignal.prepared16kSamples(samples)
        #expect(prepared.count < samples.count)
        #expect(prepared.allSatisfy { $0.isFinite && abs($0) <= 0.95 })
        #expect(VoiceEnrollmentSignal.measure(prepared, sampleRate: 16_000).rms > 0.02)
    }

    @Test("silence, constant offset and invalid PCM never become a voice sample")
    func rejectsInvalidInput() {
        for samples in [[], [Float](repeating: 0, count: 160_000), [Float](repeating: 0.2, count: 160_000), [.nan]] {
            #expect(throws: AIError.self) { try VoiceEnrollmentSignal.prepared16kSamples(samples) }
        }
        #expect(VoiceEnrollmentSignal.measure([0.2], sampleRate: .nan).meterLevel == 0)
    }
}
