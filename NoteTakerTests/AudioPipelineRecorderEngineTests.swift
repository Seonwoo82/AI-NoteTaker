@testable import AudioPipeline
@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct AudioPipelineRecorderEngineTests {
    @Test("AudioPipelineRecorderEngine retries pending cleanup before creating another capture")
    func retriesPendingCleanupBeforeCreatingAnotherCapture() async throws {
        let firstSession = RecorderEngineCaptureSessionSpy(stopBehavior: .failsOnceThenSucceeds)
        let secondSession = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let factory = RecorderEngineCaptureSessionFactory([firstSession, secondSession])
        let engine = AudioPipelineRecorderEngine(makeCaptureSession: factory.make)
        let firstRequest = recorderRequest()
        let secondRequest = recorderRequest()

        _ = try await engine.start(firstRequest)
        await #expect(throws: RecorderEngineError.self) {
            _ = try await engine.stop()
        }

        #expect(factory.makeCallCount == 1)
        #expect(await firstSession.stopCallCount == 1)
        #expect(await firstSession.hasPendingCleanup())

        _ = try await engine.start(secondRequest)

        #expect(factory.makeCallCount == 2)
        #expect(await firstSession.stopCallCount == 2)
        #expect(await !firstSession.hasPendingCleanup())
        #expect(await secondSession.startCallCount == 1)
    }

    @Test("AudioPipelineRecorderEngine keeps the previous preview when replacement merge fails")
    func keepsPreviousPreviewWhenReplacementMergeFails() async throws {
        let firstSession = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let secondSession = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let factory = RecorderEngineCaptureSessionFactory([firstSession, secondSession])
        let exporter = FailingPreviewExporter()
        let engine = AudioPipelineRecorderEngine(
            makeCaptureSession: factory.make,
            merger: AudioSegmentMerger(export: { _, destination, presetName in
                try await exporter.export(destination: destination, presetName: presetName)
            })
        )
        let request = recorderRequest()
        _ = try await engine.start(request)
        _ = try await engine.pause()
        try await engine.resume()
        let previewURL = request.directoryURL
            .appending(path: "segments", directoryHint: .isDirectory)
            .appending(path: "preview.m4a")
        let originalPreviewBytes = Data("old preview".utf8)
        try originalPreviewBytes.write(to: previewURL)

        await #expect(throws: RecorderEngineError.self) {
            _ = try await engine.pause()
        }

        #expect(try Data(contentsOf: previewURL) == originalPreviewBytes)
        #expect(await exporter.attemptCount == 1)
    }

    @Test("AudioPipelineRecorderEngine starts fresh after non pending runtime terminal cleanup")
    func startsFreshAfterNonPendingRuntimeTerminalCleanup() async throws {
        let firstSession = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let secondSession = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let factory = RecorderEngineCaptureSessionFactory([firstSession, secondSession])
        let engine = AudioPipelineRecorderEngine(makeCaptureSession: factory.make)

        _ = try await engine.start(recorderRequest())
        await firstSession.triggerTerminalFailure(.deviceDisconnected)
        await waitForEngineState { engine.state == .idle }

        _ = try await engine.start(recorderRequest())

        #expect(factory.makeCallCount == 2)
        #expect(await firstSession.stopCallCount == 0)
        #expect(await secondSession.startCallCount == 1)
        #expect(engine.state == .recording)
    }

    @Test("AudioPipelineRecorderEngine stop publishes merged media duration for two runs")
    func stopPublishesMergedMediaDurationForTwoRuns() async throws {
        let session = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let factory = RecorderEngineCaptureSessionFactory([session])
        let engine = AudioPipelineRecorderEngine(makeCaptureSession: factory.make)
        let request = recorderRequest()

        _ = try await engine.start(request)
        _ = try await engine.pause()
        try await engine.resume()
        let result = try await engine.stop()

        #expect(result.duration > 1.8)
        #expect(result.duration < 2.2)
    }

    @Test("AudioPipelineRecorderEngine polls capture progress into scoped level events")
    func pollsCaptureProgressIntoScopedLevelEvents() async throws {
        let session = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        await session.setProgress(CaptureProgress(duration: 1.5, microphonePeak: 0.25, systemPeak: 0.75))
        let factory = RecorderEngineCaptureSessionFactory([session])
        let engine = AudioPipelineRecorderEngine(makeCaptureSession: factory.make)
        let request = recorderRequest()
        var iterator = engine.events.makeAsyncIterator()

        _ = try await engine.start(request)

        let event = await iterator.next()

        #expect(event == .levels(
            recordingID: request.id,
            progress: CaptureProgress(duration: 1.5, microphonePeak: 0.25, systemPeak: 0.75)
        ))
    }

    @Test("AudioPipelineRecorderEngine passes live audio handler into capture configuration")
    func passesLiveAudioHandlerIntoCaptureConfiguration() async throws {
        let session = RecorderEngineCaptureSessionSpy(stopBehavior: .succeeds)
        let factory = RecorderEngineCaptureSessionFactory([session])
        let collector = LiveAudioSampleCollector()
        let engine = AudioPipelineRecorderEngine(makeCaptureSession: factory.make)
        engine.liveAudioHandler = collector.append
        let request = recorderRequest()

        _ = try await engine.start(request)
        await session.emitConfiguredLiveAudio(samples: [0.1, 0.2], sampleRate: 16_000, startTime: 1.25)
        _ = try await engine.stop()

        #expect(collector.chunks() == [
            LiveAudioSamples(samples: [0.1, 0.2], sampleRate: 16_000, startTime: 1.25)
        ])
    }
}

@MainActor
private final class RecorderEngineCaptureSessionFactory {
    private var sessions: [RecorderEngineCaptureSessionSpy]
    private(set) var makeCallCount = 0

    init(_ sessions: [RecorderEngineCaptureSessionSpy]) {
        self.sessions = sessions
    }

    func make() -> any AudioPipelineCaptureSessioning {
        makeCallCount += 1
        return sessions.removeFirst()
    }
}

private enum RecorderEngineCaptureSessionError: Error, Equatable {
    case stopFailed
}

private actor RecorderEngineCaptureSessionSpy: AudioPipelineCaptureSessioning {
    enum StopBehavior {
        case succeeds
        case failsOnceThenSucceeds
    }

    private let stopBehavior: StopBehavior
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var outputURL: URL?
    private var cleanupPending = false
    private var currentProgress: CaptureProgress?
    private var liveAudioHandler: LiveAudioSampleHandler?
    private let stream: AsyncStream<CaptureTerminalEvent>
    private let continuation: AsyncStream<CaptureTerminalEvent>.Continuation

    init(stopBehavior: StopBehavior) {
        self.stopBehavior = stopBehavior
        var capturedContinuation: AsyncStream<CaptureTerminalEvent>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func start(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        startCallCount += 1
        outputURL = configuration.outputURL
        liveAudioHandler = configuration.liveAudioHandler
        try Self.writeReadableAACFixture(to: configuration.outputURL)
        cleanupPending = true
        return CaptureStartResult(
            aggregateSampleRate: 48_000,
            channelMap: InputChannelMap(
                microphoneChannels: [0],
                systemChannels: [],
                bufferLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
                confidence: .terminalType
            )
        )
    }

    func stop() async throws -> FinishedRecordingOutput {
        stopCallCount += 1
        switch stopBehavior {
        case .succeeds:
            cleanupPending = false
            return try finishedOutput()
        case .failsOnceThenSucceeds:
            if stopCallCount == 1 {
                cleanupPending = true
                throw RecorderEngineCaptureSessionError.stopFailed
            }
            cleanupPending = false
            return try finishedOutput()
        }
    }

    func pause() async throws -> RecordingSegmentOutput {
        guard let outputURL else {
            throw RecorderEngineCaptureSessionError.stopFailed
        }
        return RecordingSegmentOutput(
            url: outputURL,
            duration: 1,
            outputFramesWritten: 48_000
        )
    }

    func progress() -> CaptureProgress? {
        currentProgress
    }

    func setProgress(_ progress: CaptureProgress?) {
        currentProgress = progress
    }

    func emitConfiguredLiveAudio(samples: [Float], sampleRate: Double, startTime: Double) {
        liveAudioHandler?(LiveAudioSamples(samples: samples, sampleRate: sampleRate, startTime: startTime))
    }

    func resume(outputURL: URL) async throws {
        self.outputURL = outputURL
        try Self.writeReadableAACFixture(to: outputURL)
    }

    func hasPendingCleanup() -> Bool {
        cleanupPending
    }

    func terminalEvents() -> AsyncStream<CaptureTerminalEvent> {
        stream
    }

    func triggerTerminalFailure(_ error: AudioCaptureError) {
        cleanupPending = false
        continuation.yield(CaptureTerminalEvent(generation: 1, error: error))
    }

    private func finishedOutput() throws -> FinishedRecordingOutput {
        guard let outputURL else {
            throw RecorderEngineCaptureSessionError.stopFailed
        }
        return FinishedRecordingOutput(
            url: outputURL,
            duration: 1,
            sampleRate: 48_000,
            channelCount: 2,
            bars: [],
            stats: RecordingWriterStats(
                inputFramesRead: 48_000,
                outputFramesWritten: 48_000,
                fileWriteCalls: 1,
                barsEmitted: 0,
                ringDroppedFrames: 0,
                ringOverflowCount: 0,
                microphonePeak: 0.5,
                systemPeak: 0.5
            ),
            warnings: []
        )
    }

    private static func writeReadableAACFixture(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
        else {
            throw RecorderEngineCaptureSessionError.stopFailed
        }
        buffer.frameLength = 48_000
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
}

private final class LiveAudioSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChunks: [LiveAudioSamples] = []

    func append(_ chunk: LiveAudioSamples) {
        lock.lock()
        recordedChunks.append(chunk)
        lock.unlock()
    }

    func chunks() -> [LiveAudioSamples] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChunks
    }
}

private actor FailingPreviewExporter {
    private(set) var attemptCount = 0

    func export(destination: URL, presetName: String) async throws {
        attemptCount += 1
        _ = destination
        _ = presetName
        throw RecorderEngineCaptureSessionError.stopFailed
    }
}

@MainActor
private func waitForEngineState(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        await Task.yield()
    }
}

private func recorderRequest() -> RecorderRequest {
    let id = UUID()
    let directoryURL = FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerAudioPipelineRecorderEngineTests-\(id.uuidString)", directoryHint: .isDirectory)
    return RecorderRequest(
        id: id,
        directoryURL: directoryURL,
        mode: .micAndSystem,
        microphoneUID: nil,
        microphoneGain: 1,
        systemGain: 1
    )
}
