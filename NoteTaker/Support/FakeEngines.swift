@preconcurrency import AVFAudio
import AudioPipeline
import Foundation

@MainActor
final class FakeRecorderEngine: RecorderEngine {
    private(set) var state: RecorderState = .idle
    private(set) var startRequests: [RecorderRequest] = []
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var confirmPublishedCallCount = 0
    var startError: Error?
    var stopError: Error?
    var resultDuration: TimeInterval = 1.25
    var startWarnings: [String] = []
    var resultWarnings: [String] = []
    var resultURL: URL?
    var onStart: ((RecorderRequest) -> Void)?

    private let stream: AsyncStream<RecorderEvent>
    private let continuation: AsyncStream<RecorderEvent>.Continuation

    var events: AsyncStream<RecorderEvent> { stream }

    init() {
        var capturedContinuation: AsyncStream<RecorderEvent>.Continuation!
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func start(_ request: RecorderRequest) async throws -> RecorderStart {
        startRequests.append(request)
        onStart?(request)
        if let startError {
            throw startError
        }
        try Self.writeReadableAACFixture(to: request.directoryURL.appending(path: "audio.m4a"))
        state = .recording
        return RecorderStart(warnings: startWarnings)
    }

    func pause() async throws -> RecorderPreview {
        pauseCallCount += 1
        state = .paused
        guard let request = startRequests.last else {
            throw RecorderEngineError.failed(message: "Recording has not started", settingsURL: nil, keepsPartialFile: false)
        }
        let previewURL = request.directoryURL
            .appending(path: "segments", directoryHint: .isDirectory)
            .appending(path: "preview.m4a")
        try Self.writeReadableAACFixture(to: previewURL)
        return RecorderPreview(
            url: previewURL,
            duration: resultDuration
        )
    }

    func resume() async throws {
        resumeCallCount += 1
        state = .recording
    }

    func stop() async throws -> RecorderResult {
        stopCallCount += 1
        if let stopError {
            throw stopError
        }
        state = .stopped
        guard let request = startRequests.last else {
            throw RecorderEngineError.failed(message: "Recording has not started", settingsURL: nil, keepsPartialFile: false)
        }
        return RecorderResult(
            url: resultURL ?? request.directoryURL.appending(path: "audio.m4a"),
            duration: resultDuration,
            warnings: resultWarnings
        )
    }

    func confirmPublished() async {
        confirmPublishedCallCount += 1
    }

    func fail(message: String, settingsURL: URL? = nil, keepsPartialFile: Bool) {
        guard let recordingID = startRequests.last?.id else { return }
        emitFailure(
            recordingID: recordingID,
            message: message,
            settingsURL: settingsURL,
            keepsPartialFile: keepsPartialFile
        )
    }

    func emitFailure(
        recordingID: UUID,
        message: String,
        settingsURL: URL? = nil,
        keepsPartialFile: Bool
    ) {
        continuation.yield(.recordingFailed(
            recordingID: recordingID,
            message: message,
            settingsURL: settingsURL,
            keepsPartialFile: keepsPartialFile
        ))
    }

    func emitProgress(
        recordingID: UUID,
        duration: TimeInterval,
        microphonePeak: Float,
        systemPeak: Float
    ) {
        continuation.yield(.levels(
            recordingID: recordingID,
            progress: CaptureProgress(
                duration: duration,
                microphonePeak: microphonePeak,
                systemPeak: systemPeak
            )
        ))
    }

    func emitStaleFailure(message: String, settingsURL: URL? = nil, keepsPartialFile: Bool) {
        guard startRequests.count >= 2 else { return }
        let staleID = startRequests[startRequests.index(before: startRequests.index(before: startRequests.endIndex))].id
        continuation.yield(.recordingFailed(
            recordingID: staleID,
            message: message,
            settingsURL: settingsURL,
            keepsPartialFile: keepsPartialFile
        ))
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
        ) else {
            throw RecorderEngineError.failed(message: "Could not create test audio format", settingsURL: nil, keepsPartialFile: false)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else {
            throw RecorderEngineError.failed(message: "Could not create test audio buffer", settingsURL: nil, keepsPartialFile: false)
        }
        buffer.frameLength = 4_800

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}

@MainActor
final class FakePlayerEngine: PlayerEngine {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var loadError: Error?
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var playCallCount = 0
    private(set) var loadedURLs: [URL] = []
    private(set) var seekRequests: [TimeInterval] = []
    var onStop: (() -> Void)?
    private var finishHandler: (@MainActor () -> Void)?

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        finishHandler = handler
    }

    func load(url: URL) async throws {
        if let loadError {
            throw loadError
        }
        loadedURLs.append(url)
        currentTime = 0
        duration = 0
    }

    func play() async throws {
        playCallCount += 1
        isPlaying = true
    }

    func pause() async {
        pauseCallCount += 1
        isPlaying = false
    }

    func seek(to time: TimeInterval) async {
        seekRequests.append(time)
        currentTime = time
    }

    func stop() async {
        stopCallCount += 1
        isPlaying = false
        currentTime = 0
        onStop?()
    }

    func finish() {
        isPlaying = false
        currentTime = duration
        finishHandler?()
    }
}
