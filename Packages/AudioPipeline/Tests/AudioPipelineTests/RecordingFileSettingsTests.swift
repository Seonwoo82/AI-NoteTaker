import AVFAudio
import AudioPipeline
import Foundation
import Testing

@Test("AAC writer settings create fixed stereo 48 kHz 128 kbps m4a files")
func aacWriterSettingsCreateFixedStereo48k128kbpsM4AFiles() throws {
    let settings = RecordingFileSettings.aacM4A

    #expect(settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
    #expect(settings[AVSampleRateKey] as? Double == 48_000)
    #expect(settings[AVNumberOfChannelsKey] as? Int == 2)
    #expect(settings[AVEncoderBitRateKey] as? Int == 128_000)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("settings-smoke.m4a")
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RecordingFileSettings.outputSampleRate,
        channels: RecordingFileSettings.outputChannelCount,
        interleaved: true
    ) else {
        throw TestFailure("could not create interleaved Float32 format")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
        throw TestFailure("could not create PCM buffer")
    }
    buffer.frameLength = 128

    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: true
    )
    try file.write(from: buffer)
    file.close()

    let reopened = try AVAudioFile(forReading: url)
    #expect(reopened.fileFormat.sampleRate == 48_000)
    #expect(reopened.fileFormat.channelCount == 2)
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
