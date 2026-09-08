import Foundation
import Testing
#if canImport(AVFAudio)
import AVFAudio
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Local speaker audio conversion")
struct LocalSpeakerAudioConversionTests {
    #if canImport(AVFAudio)
    @Test("44.1 kHz stereo files stream into bounded 16 kHz mono windows")
    func stereoFileStreamsIntoBoundedMonoWindows() throws {
        let url = temporaryAudioURL()
        try writeStereoConstantFile(url: url, duration: 45, sampleRate: 44_100, left: 0.25, right: 0.75)

        var windows: [LocalSpeakerPCMWindow] = []
        try LocalSpeakerAudioFileWindows.readMonoWindows(
            from: url,
            targetSampleRate: 16_000,
            readFrameCapacity: 4_096
        ) { window in
            windows.append(window)
        }

        #expect(windows.map(\.startTime) == [0, 10, 20, 30, 40])
        #expect(windows.map(\.samples.count) == [160_000, 160_000, 160_000, 160_000, 80_000])
        #expect(abs(windows.map(\.duration).reduce(0, +) - 45) < 0.001)
        #expect(abs(mean(of: windows[0].samples) - 0.5) < 0.01)
    }

    @Test("file conversion and single buffer conversion agree on a ten second signal")
    func fileConversionMatchesSingleBufferConversion() throws {
        let url = temporaryAudioURL()
        let samples = sineSamples(duration: 10, sampleRate: 44_100, frequency: 220, amplitude: 0.2)
        try writeMonoFile(url: url, samples: samples, sampleRate: 44_100)

        let direct = try LocalSpeakerAudioConverter.convertMonoSamplesTo16k(samples, sampleRate: 44_100)
        var windows: [LocalSpeakerPCMWindow] = []
        try LocalSpeakerAudioFileWindows.readMonoWindows(from: url, targetSampleRate: 16_000) { window in
            windows.append(window)
        }

        let fileSamples = try #require(windows.first?.samples)
        #expect(windows.count == 1)
        #expect(abs(Double(fileSamples.count - direct.count) / 16_000) < 0.001)
        #expect(abs(rms(fileSamples) - rms(direct)) < 0.02)
    }
    #endif

    @Test("window builder rejects invalid input and preserves bounded chunk timing")
    func windowBuilderRejectsInvalidInputAndPreservesTiming() {
        var invalid = LocalSpeakerPCMWindowBuilder(windowDuration: .nan, maximumBufferedDuration: -4)

        #expect(invalid.append(samples: [.nan], sampleRate: 16_000, startTime: 0).isEmpty)
        #expect(invalid.append(samples: [0.1], sampleRate: .infinity, startTime: 0).isEmpty)
        #expect(invalid.append(samples: [0.1], sampleRate: 16_000, startTime: -1).isEmpty)
        #expect(invalid.finish() == nil)

        var chunked = LocalSpeakerPCMWindowBuilder(windowDuration: 10, maximumBufferedDuration: 12)
        var emitted: [LocalSpeakerPCMWindow] = []
        for index in 0..<90 {
            emitted.append(contentsOf: chunked.append(samples: [0.1], sampleRate: 2, startTime: Double(index) * 0.5))
        }
        let tail = chunked.finish()

        #expect(emitted.map(\.startTime) == [0, 10, 20, 30])
        #expect(tail?.startTime == 40)
        #expect(tail?.duration == 5)
    }
}

#if canImport(AVFAudio)
private func writeStereoConstantFile(url: URL, duration: Double, sampleRate: Double, left: Float, right: Float) throws {
    let frameCount = Int(duration * sampleRate)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
    else {
        Issue.record("Failed to create stereo buffer")
        return
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    for frame in 0..<frameCount {
        buffer.floatChannelData?[0][frame] = left
        buffer.floatChannelData?[1][frame] = right
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func writeMonoFile(url: URL, samples: [Float], sampleRate: Double) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else {
        Issue.record("Failed to create mono buffer")
        return
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        guard let baseAddress = source.baseAddress else { return }
        buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func sineSamples(duration: Double, sampleRate: Double, frequency: Double, amplitude: Float) -> [Float] {
    let frameCount = Int(duration * sampleRate)
    return (0..<frameCount).map { frame in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
    }
}
#endif

private func mean(of samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0, +) / Float(samples.count)
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return sqrt(energy / Float(samples.count))
}

private func temporaryAudioURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalSpeakerAudioConversionTests-\(UUID().uuidString).caf")
}
