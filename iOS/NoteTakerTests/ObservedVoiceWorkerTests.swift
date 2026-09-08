import AVFoundation
import Testing

@testable import NoteTakerIOS

@Test("observed voice worker drains queued buffers and emits live samples on finish")
func observedVoiceWorkerDrainsQueuedBuffersAndEmitsLiveSamplesOnFinish() throws {
    let sampleRate = 8.0
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let url = temporaryAudioURL(extension: "caf")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let collector = LiveSampleCollector()
    let worker = ObservedVoiceAudioWorker(
        audioFile: file,
        sampleRate: sampleRate,
        liveAudioHandler: collector.append,
        failureHandler: {}
    )

    worker.consume(try pcmBuffer(format: format, samples: [0.125, 0.25]))
    worker.consume(try pcmBuffer(format: format, samples: [0.5, 0.75]))
    worker.consume(try pcmBuffer(format: format, samples: [1, -0.5]))

    let frames = try worker.finish()
    let output = try AVAudioFile(forReading: url)

    #expect(frames == 6)
    #expect(output.length == 6)
    #expect(collector.chunks() == [
        LiveAudioSamples(samples: [0.125, 0.25, 0.5, 0.75], sampleRate: sampleRate, startTime: 0),
        LiveAudioSamples(samples: [1, -0.5], sampleRate: sampleRate, startTime: 0.5)
    ])
}

@Test("observed voice worker overflows explicitly and preserves queued partial audio")
func observedVoiceWorkerOverflowsExplicitlyAndPreservesQueuedPartialAudio() throws {
    let sampleRate = 8.0
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let url = temporaryAudioURL(extension: "caf")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let gate = DispatchSemaphore(value: 0)
    let failures = FailureCollector()
    let worker = ObservedVoiceAudioWorker(
        audioFile: file,
        sampleRate: sampleRate,
        liveAudioHandler: { _ in },
        failureHandler: failures.record,
        maxPendingBuffers: 2,
        processingGate: gate
    )

    worker.consume(try pcmBuffer(format: format, samples: [0.125, 0.25]))
    worker.consume(try pcmBuffer(format: format, samples: [0.5, 0.75]))
    worker.consume(try pcmBuffer(format: format, samples: [1, -0.5]))
    gate.signal()
    gate.signal()

    #expect(throws: ObservedVoiceRecordingError.workerQueueOverflow) {
        _ = try worker.finish()
    }
    let output = try AVAudioFile(forReading: url)

    #expect(failures.count() == 1)
    #expect(output.length == 4)
}

@Test("observed voice worker reports invalid PCM format without writing")
func observedVoiceWorkerReportsInvalidPCMFormatWithoutWriting() throws {
    let validFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 8, channels: 1))
    let invalidFormat = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 8,
        channels: 1,
        interleaved: false
    ))
    let invalidBuffer = try #require(AVAudioPCMBuffer(pcmFormat: invalidFormat, frameCapacity: 2))
    invalidBuffer.frameLength = 2
    let url = temporaryAudioURL(extension: "caf")
    let file = try AVAudioFile(forWriting: url, settings: validFormat.settings)
    let failures = FailureCollector()
    let worker = ObservedVoiceAudioWorker(
        audioFile: file,
        sampleRate: 8,
        liveAudioHandler: { _ in },
        failureHandler: failures.record
    )

    worker.consume(invalidBuffer)

    #expect(throws: ObservedVoiceRecordingError.invalidInputFormat) {
        _ = try worker.finish()
    }
    let output = try AVAudioFile(forReading: url)

    #expect(failures.count() == 1)
    #expect(output.length == 0)
}

@Test("observed voice session rejects invalid input formats")
func observedVoiceSessionRejectsInvalidInputFormats() throws {
    let valid = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let invalid = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    ))

    try ObservedVoiceRecordingSession.validateInputFormat(valid)
    #expect(throws: ObservedVoiceRecordingError.invalidInputFormat) {
        try ObservedVoiceRecordingSession.validateInputFormat(invalid)
    }
}

private func temporaryAudioURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ObservedVoiceWorkerTests-\(UUID().uuidString).\(pathExtension)")
}

private func pcmBuffer(format: AVAudioFormat, samples: [Float]) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try #require(buffer.floatChannelData?[0])
    for (index, sample) in samples.enumerated() {
        channel[index] = sample
    }
    return buffer
}

private final class LiveSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveAudioSamples] = []

    func append(_ samples: LiveAudioSamples) {
        lock.lock()
        values.append(samples)
        lock.unlock()
    }

    func chunks() -> [LiveAudioSamples] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
