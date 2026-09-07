@preconcurrency import AVFAudio
import Foundation

public enum RecordingFileSettings {
    public static let outputSampleRate: Double = 48_000
    public static let outputChannelCount: AVAudioChannelCount = 2
    public static let bitRate = 128_000

    public static var aacM4A: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: Int(outputChannelCount),
            AVEncoderBitRateKey: bitRate
        ]
    }
}
