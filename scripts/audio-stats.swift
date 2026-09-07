#!/usr/bin/env swift

import AVFoundation
import Foundation

struct AudioStatsExpectations {
    var sampleRate: Double?
    var channels: Int?
    var duration: Double?
    var durationTolerance: Double = 0
    var minRMSDBFS: Double?
    var minPeakDBFS: Double?
}

struct AudioStats {
    let duration: Double
    let sampleRate: Double
    let channelCount: Int
    let rmsDBFS: [Double]
    let peakDBFS: [Double]
}

enum AudioStatsError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case unreadableFile(String)
    case unsupportedFormat
    case emptyFile
    case expectationFailures([String])

    var description: String {
        switch self {
        case .invalidArguments(let details):
            "usage: audio-stats.swift <file> [--expect-sample-rate hz] [--expect-channels count] [--expect-duration seconds] [--duration-tolerance seconds] [--min-rms-dbfs db] [--min-peak-dbfs db] (\(details))"
        case .unreadableFile(let path):
            "file is not readable: \(path)"
        case .unsupportedFormat:
            "audio file has no readable PCM channel data"
        case .emptyFile:
            "audio file contains no frames"
        case .expectationFailures(let failures):
            "audio expectations failed:\n" + failures.joined(separator: "\n")
        }
    }
}

let silenceFloorDBFS = -160.0

func decibels(amplitude: Double) -> Double {
    guard amplitude.isFinite, amplitude > 0 else {
        return silenceFloorDBFS
    }

    return max(20 * log10(amplitude), silenceFloorDBFS)
}

func parseArguments(_ arguments: [String]) throws -> (path: String, expectations: AudioStatsExpectations?) {
    guard arguments.count >= 2 else {
        throw AudioStatsError.invalidArguments("missing file")
    }

    var expectations = AudioStatsExpectations()
    var hasExpectations = false
    var index = 2
    while index < arguments.count {
        let flag = arguments[index]
        guard flag.hasPrefix("--") else {
            throw AudioStatsError.invalidArguments("unexpected argument: \(flag)")
        }
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw AudioStatsError.invalidArguments("missing value for \(flag)")
        }
        let value = arguments[valueIndex]

        switch flag {
        case "--expect-sample-rate":
            expectations.sampleRate = try parseFinitePositiveDouble(value, name: flag)
        case "--expect-channels":
            expectations.channels = try parsePositiveInt(value, name: flag)
        case "--expect-duration":
            expectations.duration = try parseFinitePositiveDouble(value, name: flag)
        case "--duration-tolerance":
            expectations.durationTolerance = try parseFiniteNonnegativeDouble(value, name: flag)
        case "--min-rms-dbfs":
            expectations.minRMSDBFS = try parseFiniteDouble(value, name: flag)
        case "--min-peak-dbfs":
            expectations.minPeakDBFS = try parseFiniteDouble(value, name: flag)
        default:
            throw AudioStatsError.invalidArguments("unknown flag: \(flag)")
        }
        hasExpectations = true
        index += 2
    }

    return (arguments[1], hasExpectations ? expectations : nil)
}

func parseFiniteDouble(_ value: String, name: String) throws -> Double {
    guard let parsed = Double(value), parsed.isFinite else {
        throw AudioStatsError.invalidArguments("invalid value for \(name): \(value)")
    }
    return parsed
}

func parseFinitePositiveDouble(_ value: String, name: String) throws -> Double {
    let parsed = try parseFiniteDouble(value, name: name)
    guard parsed > 0 else {
        throw AudioStatsError.invalidArguments("invalid value for \(name): \(value)")
    }
    return parsed
}

func parseFiniteNonnegativeDouble(_ value: String, name: String) throws -> Double {
    let parsed = try parseFiniteDouble(value, name: name)
    guard parsed >= 0 else {
        throw AudioStatsError.invalidArguments("invalid value for \(name): \(value)")
    }
    return parsed
}

func parsePositiveInt(_ value: String, name: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
        throw AudioStatsError.invalidArguments("invalid value for \(name): \(value)")
    }
    return parsed
}

func collectStats(path: String) throws -> AudioStats {
    guard FileManager.default.isReadableFile(atPath: path) else {
        throw AudioStatsError.unreadableFile(path)
    }

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    guard channelCount > 0 else {
        throw AudioStatsError.unsupportedFormat
    }

    let sampleRate = format.sampleRate
    let frameCount = file.length
    guard frameCount > 0, sampleRate > 0 else {
        throw AudioStatsError.emptyFile
    }

    let chunkCapacity: AVAudioFrameCount = 65_536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
        throw AudioStatsError.unsupportedFormat
    }

    var sumSquares = Array(repeating: 0.0, count: channelCount)
    var peaks = Array(repeating: 0.0, count: channelCount)
    var framesRead: AVAudioFramePosition = 0

    while framesRead < frameCount {
        let remaining = frameCount - framesRead
        buffer.frameLength = AVAudioFrameCount(min(Int64(chunkCapacity), remaining))
        try file.read(into: buffer)

        let frames = Int(buffer.frameLength)
        guard frames > 0 else {
            break
        }

        if let channelData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame])
                    sumSquares[channel] += sample * sample
                    peaks[channel] = max(peaks[channel], abs(sample))
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = data[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame]) / Double(Int16.max)
                    sumSquares[channel] += sample * sample
                    peaks[channel] = max(peaks[channel], abs(sample))
                }
            }
        } else {
            throw AudioStatsError.unsupportedFormat
        }

        framesRead += AVAudioFramePosition(frames)
    }

    guard framesRead > 0 else {
        throw AudioStatsError.emptyFile
    }

    let rms = sumSquares.map { sqrt($0 / Double(framesRead)) }
    return AudioStats(
        duration: Double(frameCount) / sampleRate,
        sampleRate: sampleRate,
        channelCount: channelCount,
        rmsDBFS: rms.map(decibels),
        peakDBFS: peaks.map(decibels)
    )
}

func printStats(_ stats: AudioStats) {
    print(String(format: "duration: %.3f s", stats.duration))
    print(String(format: "sampleRate: %.1f Hz", stats.sampleRate))
    print("channels: \(stats.channelCount)")
    for channel in 0..<stats.channelCount {
        print(String(format: "channel %d RMS: %.2f dBFS", channel + 1, stats.rmsDBFS[channel]))
        print(String(format: "channel %d peak: %.2f dBFS", channel + 1, stats.peakDBFS[channel]))
    }
}

func validate(_ stats: AudioStats, against expectations: AudioStatsExpectations) throws {
    var failures: [String] = []
    if let expected = expectations.sampleRate, stats.sampleRate != expected {
        failures.append(String(format: "sampleRate expected %.1f Hz, got %.1f Hz", expected, stats.sampleRate))
    }
    if let expected = expectations.channels, stats.channelCount != expected {
        failures.append("channels expected \(expected), got \(stats.channelCount)")
    }
    if let expected = expectations.duration {
        let delta = abs(stats.duration - expected)
        if delta > expectations.durationTolerance {
            failures.append(String(format: "duration expected %.3f ± %.3f s, got %.3f s", expected, expectations.durationTolerance, stats.duration))
        }
    }
    if let minimum = expectations.minRMSDBFS {
        for (index, value) in stats.rmsDBFS.enumerated() where !value.isFinite || value <= minimum {
            failures.append(String(format: "channel %d RMS expected > %.2f dBFS, got %.2f dBFS", index + 1, minimum, value))
        }
    }
    if let minimum = expectations.minPeakDBFS {
        for (index, value) in stats.peakDBFS.enumerated() where !value.isFinite || value <= minimum {
            failures.append(String(format: "channel %d peak expected > %.2f dBFS, got %.2f dBFS", index + 1, minimum, value))
        }
    }
    if !failures.isEmpty {
        throw AudioStatsError.expectationFailures(failures)
    }
}

func run(arguments: [String]) throws {
    let parsed = try parseArguments(arguments)
    let stats = try collectStats(path: parsed.path)
    printStats(stats)
    if let expectations = parsed.expectations {
        try validate(stats, against: expectations)
        print("expectations: pass")
    }
}

do {
    try run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
