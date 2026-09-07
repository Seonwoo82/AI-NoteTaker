import Testing
import AudioPipeline
import AVFoundation
import Foundation

@Test("AudioPipeline exposes an M0 readiness marker")
func audioPipelineReadinessMarkerIsAvailable() {
    #expect(AudioPipeline.readiness == "AudioPipeline M0 ready")
}

@Test("RecordingConfiguration defaults the aggregate clock source to microphone")
func recordingConfigurationDefaultsClockSourceToMicrophone() {
    let configuration = RecordingConfiguration(
        mode: .micAndSystem,
        microphoneUID: nil,
        outputURL: URL(fileURLWithPath: "/tmp/notetaker-test-output.m4a"),
        microphoneGain: 1,
        systemGain: 1
    )

    #expect(configuration.clockSource == .microphone)
}

@Test("audio stats reports finite dBFS values for silent audio")
func audioStatsReportsFiniteValuesForSilentAudio() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let fixtureURL = temporaryDirectory.appendingPathComponent("silent.caf")
    try writeSilentAudio(to: fixtureURL)

    let repositoryRoot = try findRepositoryRoot()
    let scriptURL = repositoryRoot.appendingPathComponent("scripts/audio-stats.swift")
    let result = try runSwiftScript(scriptURL, argument: fixtureURL, workingDirectory: repositoryRoot)

    #expect(result.exitCode == 0, Comment(rawValue: result.standardError))

    let output = result.standardOutput.lowercased()
    #expect(!output.contains("inf"))
    #expect(!output.contains("nan"))

    let dbfsValues = result.standardOutput
        .split(separator: "\n")
        .filter { $0.contains("RMS:") || $0.contains("peak:") }
        .compactMap { line -> Double? in
            line.split(separator: " ").reversed().dropFirst().compactMap(Double.init).first
        }

    #expect(dbfsValues.count == 2)
    #expect(dbfsValues.allSatisfy { $0.isFinite })
}

@Test("audio stats expectation mode passes for deterministic stereo tone")
func audioStatsExpectationModePassesForTone() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fixtureURL = temporaryDirectory.appendingPathComponent("tone.caf")
    try writeToneAudio(to: fixtureURL, sampleRate: 48_000, channels: 2, duration: 1.0, amplitude: 0.25)

    let result = try runAudioStats(arguments: [
        fixtureURL.path,
        "--expect-sample-rate", "48000",
        "--expect-channels", "2",
        "--expect-duration", "1.0",
        "--duration-tolerance", "1.0",
        "--min-rms-dbfs", "-50",
        "--min-peak-dbfs", "-30"
    ])

    #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
    #expect(result.standardOutput.contains("expectations: pass"))
}

@Test("audio stats expectation mode fails for silent audio")
func audioStatsExpectationModeFailsForSilentAudio() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fixtureURL = temporaryDirectory.appendingPathComponent("silent.caf")
    try writeSilentAudio(to: fixtureURL, sampleRate: 48_000, channels: 2)

    let result = try runAudioStats(arguments: [
        fixtureURL.path,
        "--expect-sample-rate", "48000",
        "--expect-channels", "2",
        "--expect-duration", "1.0",
        "--duration-tolerance", "1.0",
        "--min-rms-dbfs", "-50",
        "--min-peak-dbfs", "-30"
    ])

    #expect(result.exitCode != 0)
    #expect(result.standardError.contains("RMS"))
    #expect(result.standardError.contains("peak"))
}

@Test("audio stats expectation mode fails for mismatched format")
func audioStatsExpectationModeFailsForWrongFormat() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fixtureURL = temporaryDirectory.appendingPathComponent("wrong-format.caf")
    try writeSilentAudio(to: fixtureURL, sampleRate: 44_100, channels: 1)

    let result = try runAudioStats(arguments: [
        fixtureURL.path,
        "--expect-sample-rate", "48000",
        "--expect-channels", "2"
    ])

    #expect(result.exitCode != 0)
    #expect(result.standardError.contains("sampleRate"))
    #expect(result.standardError.contains("channels"))
}

@Test("audio stats validates expectation CLI flags")
func audioStatsValidatesExpectationFlags() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fixtureURL = temporaryDirectory.appendingPathComponent("tone.caf")
    try writeToneAudio(to: fixtureURL, sampleRate: 48_000, channels: 2, duration: 1.0, amplitude: 0.25)

    let missingValue = try runAudioStats(arguments: [fixtureURL.path, "--expect-channels"])
    #expect(missingValue.exitCode != 0)
    #expect(missingValue.standardError.contains("missing value"))

    let unknownFlag = try runAudioStats(arguments: [fixtureURL.path, "--bogus", "1"])
    #expect(unknownFlag.exitCode != 0)
    #expect(unknownFlag.standardError.contains("unknown flag"))
}

private struct ScriptResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private func makeTemporaryDirectory() throws -> URL {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    return temporaryDirectory
}

private func writeSilentAudio(
    to url: URL,
    sampleRate: Double = 44_100,
    channels: AVAudioChannelCount = 1
) throws {
    let frameCount: AVAudioFrameCount = 4_096
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw CocoaError(.coderInvalidValue)
    }
    buffer.frameLength = frameCount

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func writeToneAudio(
    to url: URL,
    sampleRate: Double,
    channels: AVAudioChannelCount,
    duration: Double,
    amplitude: Float
) throws {
    let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw CocoaError(.coderInvalidValue)
    }
    buffer.frameLength = frameCount
    guard let data = buffer.floatChannelData else {
        throw CocoaError(.coderInvalidValue)
    }

    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / sampleRate
            data[channel][frame] = amplitude * Float(sin(phase))
        }
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func findRepositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath)

    while candidate.path != "/" {
        let scriptURL = candidate.appendingPathComponent("scripts/audio-stats.swift")
        if FileManager.default.isReadableFile(atPath: scriptURL.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

private func runSwiftScript(
    _ scriptURL: URL,
    argument: URL,
    workingDirectory: URL
) throws -> ScriptResult {
    try runSwiftScript(scriptURL, arguments: [argument.path], workingDirectory: workingDirectory)
}

private func runAudioStats(arguments: [String]) throws -> ScriptResult {
    let repositoryRoot = try findRepositoryRoot()
    let scriptURL = repositoryRoot.appendingPathComponent("scripts/audio-stats.swift")
    return try runSwiftScript(scriptURL, arguments: arguments, workingDirectory: repositoryRoot)
}

private func runSwiftScript(
    _ scriptURL: URL,
    arguments: [String],
    workingDirectory: URL
) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", scriptURL.path] + arguments
    process.currentDirectoryURL = workingDirectory

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
        exitCode: process.terminationStatus,
        standardOutput: String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "",
        standardError: String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}
