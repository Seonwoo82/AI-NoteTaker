import Testing
import Foundation
import AVFAudio
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite
struct MeetingAudioChunkerTests {
    @Test("chunk count uses readable frames and splits every two minutes")
    func chunkCountUsesReadableFramesAndSplitsEveryTwoMinutes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "two-and-a-half-minutes.caf")
        try writeCAF(url: url, sampleRate: 8_000, channels: 1, seconds: 250) { second, _, _ in
            second < 120 ? 0.15 : 0.35
        }

        let chunker = MeetingAudioChunker()

        let count = try await chunker.chunkCount(for: url)
        let first = try await chunker.chunk(for: url, index: 0)
        let third = try await chunker.chunk(for: url, index: 2)

        #expect(count == 3)
        #expect(first.format == "wav")
        #expect(first.startTime == 0)
        #expect(abs(first.duration - 120) < 0.001)
        #expect(third.startTime == 240)
        #expect(abs(third.duration - 10) < 0.001)
    }

    @Test("chunk output is readable mono sixteen kilohertz PCM WAV")
    func chunkOutputIsReadableMonoSixteenKilohertzPCMWAV() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "source-44100.caf")
        try writeCAF(url: url, sampleRate: 44_100, channels: 1, seconds: 1) { _, frame, sampleRate in
            frame < Int(sampleRate / 2) ? 0.6 : -0.6
        }

        let chunk = try await MeetingAudioChunker().chunk(for: url, index: 0)
        let outputURL = root.appending(path: "chunk.wav")
        try chunk.data.write(to: outputURL)
        let output = try AVAudioFile(forReading: outputURL)

        #expect(chunk.data.starts(with: Data("RIFF".utf8)))
        #expect(chunk.data[8..<12] == Data("WAVE".utf8))
        #expect(output.fileFormat.channelCount == 1)
        #expect(Int(output.fileFormat.sampleRate) == 16_000)
        #expect(output.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(abs(Double(output.length) / output.fileFormat.sampleRate - 1) < 0.01)
    }

    @Test("stereo input is downmixed by averaging channels")
    func stereoInputIsDownmixedByAveragingChannels() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "stereo.caf")
        try writeCAF(url: url, sampleRate: 16_000, channels: 2, seconds: 1) { _, _, _, channel in
            channel == 0 ? 0.8 : -0.4
        }

        let chunk = try await MeetingAudioChunker().chunk(for: url, index: 0)
        let outputURL = root.appending(path: "downmixed.wav")
        try chunk.data.write(to: outputURL)
        let output = try AVAudioFile(forReading: outputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 1))
        try output.read(into: buffer, frameCount: 1)
        let sample = try #require(buffer.floatChannelData?[0][0])

        #expect(abs(sample - 0.2) < 0.02)
    }

    @Test("invalid files, empty files, and invalid indexes throw AIError")
    func invalidInputsThrowAIError() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appending(path: "missing.caf")
        let empty = root.appending(path: "empty.caf")
        try writeCAF(url: empty, sampleRate: 16_000, channels: 1, seconds: 0) { _, _, _ in 0 }
        let chunker = MeetingAudioChunker()

        await #expect(throws: AIError.self) {
            _ = try await chunker.chunkCount(for: missing)
        }
        await #expect(throws: AIError.self) {
            _ = try await chunker.chunkCount(for: empty)
        }
        await #expect(throws: AIError.self) {
            _ = try await chunker.chunk(for: empty, index: 0)
        }
        await #expect(throws: AIError.self) {
            _ = try await chunker.chunk(for: empty, index: -1)
        }
        await #expect(throws: AIError.self) {
            _ = try await chunker.chunk(for: empty, index: 1)
        }
    }

    @Test("chunk conversion observes task cancellation before work starts")
    func chunkConversionObservesTaskCancellationBeforeWorkStarts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "cancel.caf")
        try writeCAF(url: url, sampleRate: 16_000, channels: 1, seconds: 1) { _, _, _ in 0.1 }
        let chunker = MeetingAudioChunker()

        let task = Task {
            try await chunker.chunk(for: url, index: 0)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "MeetingAudioChunkerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeCAF(
    url: URL,
    sampleRate: Double,
    channels: AVAudioChannelCount,
    seconds: Int,
    sample: (Int, Int, Double) -> Float
) throws {
    try writeCAF(url: url, sampleRate: sampleRate, channels: channels, seconds: seconds) { second, frame, rate, _ in
        sample(second, frame, rate)
    }
}

private func writeCAF(
    url: URL,
    sampleRate: Double,
    channels: AVAudioChannelCount,
    seconds: Int,
    sample: (Int, Int, Double, Int) -> Float
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ))
    let framesPerSecond = AVAudioFrameCount(sampleRate.rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerSecond))
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for second in 0..<seconds {
            buffer.frameLength = framesPerSecond
            for channelIndex in 0..<Int(channels) {
                let channel = try #require(buffer.floatChannelData?[channelIndex])
                for frame in 0..<Int(framesPerSecond) {
                    channel[frame] = sample(second, frame, sampleRate, channelIndex)
                }
            }
            try file.write(from: buffer)
        }
    }
}
