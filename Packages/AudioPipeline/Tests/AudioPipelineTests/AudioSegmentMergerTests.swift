@testable import AudioPipeline
import AVFoundation
import AVFAudio
import Foundation
import Testing

@Test("AudioSegmentMerger merges readable AAC segments in lexical run order")
func audioSegmentMergerMergesReadableAACSegmentsInLexicalRunOrder() async throws {
    let directory = try temporaryMergerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("000.m4a")
    let second = directory.appendingPathComponent("001.m4a")
    try writeAACFixture(to: first, frameCount: 4_800, frequency: 440)
    try writeAACFixture(to: second, frameCount: 2_400, frequency: 660)
    let destination = directory.appendingPathComponent("audio.m4a")

    let output = try await AudioSegmentMerger().merge([second, first], to: destination)

    #expect(output.url == destination)
    let merged = try AVAudioFile(forReading: destination)
    #expect(merged.fileFormat.sampleRate == 48_000)
    #expect(merged.fileFormat.channelCount == 2)
    #expect(try await audioFormatIDs(in: destination).contains(kAudioFormatMPEG4AAC))
    expectMergerDuration(output.duration, equals: 0.15)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
}

@Test("AudioSegmentMerger passthrough failure leaves sources and destination untouched without retrying")
func audioSegmentMergerPassthroughFailureLeavesSourcesAndDestinationUntouchedWithoutRetrying() async throws {
    let directory = try temporaryMergerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("000.m4a")
    let second = directory.appendingPathComponent("001.m4a")
    try writeAACFixture(to: first, frameCount: 1_024, frequency: 440)
    try writeAACFixture(to: second, frameCount: 1_024, frequency: 660)
    let firstBytes = try Data(contentsOf: first)
    let secondBytes = try Data(contentsOf: second)
    let destination = directory.appendingPathComponent("audio.m4a")
    let exporter = FailingSegmentExporter()

    do {
        _ = try await AudioSegmentMerger(export: { _, destination, presetName in
            try await exporter.export(destination: destination, presetName: presetName)
        }).merge([first, second], to: destination)
        Issue.record("merge unexpectedly succeeded")
    } catch AudioCaptureError.fileWriteFailed(let message) {
        #expect(message.contains("Task5PassthroughFailure"))
        #expect(message.contains("9182"))
        #expect(message.contains("forced passthrough failure"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    let attempts = await exporter.attempts
    #expect(attempts == [ExportAttempt(presetName: AVAssetExportPresetPassthrough, pathExtension: "mp4")])
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: first) == firstBytes)
    #expect(try Data(contentsOf: second) == secondBytes)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".merge.m4a") || $0.hasSuffix(".merge.mp4") }
    #expect(leftovers.isEmpty)
}

@Test("AudioSegmentMerger copies one readable segment without using an exporter")
func audioSegmentMergerCopiesOneReadableSegmentWithoutUsingExporter() async throws {
    let directory = try temporaryMergerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("000.m4a")
    try writeAACFixture(to: source, frameCount: 4_800, frequency: 440)
    let sourceBytes = try Data(contentsOf: source)
    let destination = directory.appendingPathComponent("audio.m4a")

    let output = try await AudioSegmentMerger(export: { _, _, _ in
        throw MergerTestFailure("single segment path must not export")
    }).merge([source], to: destination)

    #expect(output.url == destination)
    let copied = try AVAudioFile(forReading: destination)
    #expect(copied.fileFormat.sampleRate == 48_000)
    #expect(copied.fileFormat.channelCount == 2)
    #expect(try await audioFormatIDs(in: destination).contains(kAudioFormatMPEG4AAC))
    expectMergerDuration(output.duration, equals: 0.1)
    #expect(try Data(contentsOf: source) == sourceBytes)
}

@Test("AudioSegmentMerger rejects empty input and leaves existing destination untouched")
func audioSegmentMergerRejectsEmptyInputAndExistingDestination() async throws {
    let directory = try temporaryMergerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("audio.m4a")

    await #expect(throws: AudioCaptureError.self) {
        _ = try await AudioSegmentMerger().merge([], to: destination)
    }

    let original = Data("existing".utf8)
    try original.write(to: destination)
    let source = directory.appendingPathComponent("000.m4a")
    try writeAACFixture(to: source, frameCount: 1_024, frequency: 330)

    await #expect(throws: AudioCaptureError.outputAlreadyExists(destination.path)) {
        _ = try await AudioSegmentMerger().merge([source], to: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

private func temporaryMergerDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeAACFixture(to url: URL, frameCount: Int, frequency: Double) throws {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
    else {
        throw MergerTestFailure("could not create fixture format")
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    for frame in 0..<frameCount {
        let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000)) * 0.2
        buffer.floatChannelData?[0][frame] = sample
        buffer.floatChannelData?[1][frame] = sample
    }
    try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
    ).write(from: buffer)
}

private struct MergerTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct ExportAttempt: Equatable, Sendable {
    let presetName: String
    let pathExtension: String
}

private actor FailingSegmentExporter {
    private(set) var attempts: [ExportAttempt] = []

    func export(destination: URL, presetName: String) async throws {
        attempts.append(ExportAttempt(presetName: presetName, pathExtension: destination.pathExtension))
        throw NSError(
            domain: "Task5PassthroughFailure",
            code: 9182,
            userInfo: [NSLocalizedDescriptionKey: "forced passthrough failure"]
        )
    }
}

private func audioFormatIDs(in url: URL) async throws -> [AudioFormatID] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw MergerTestFailure("missing audio track")
    }
    return try await track.load(.formatDescriptions).compactMap { description in
        CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID
    }
}

private func expectMergerDuration(
    _ actual: TimeInterval,
    equals expected: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= 1_024 / 48_000, sourceLocation: sourceLocation)
}
