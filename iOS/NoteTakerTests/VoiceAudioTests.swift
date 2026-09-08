import AVFoundation
#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Test("VoiceRecorder finalizes a playable microphone note into the library")
func voiceRecorderFinalizesPlayableMicrophoneNoteIntoLibrary() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let audio = try validSilentM4AData()
    let recorder = VoiceRecorder(backend: StubRecordingBackend(result: .success(duration: 1.25, audioData: audio)))

    await recorder.start(library: store, mode: .micOnly)
    let recording = await recorder.finish(library: store)

    let saved = try #require(recording)
    #expect(saved.duration == 1.25)
    #expect(saved.mode == .micOnly)
    #expect(store.recording(id: saved.id) == saved)
    #expect(FileManager.default.fileExists(atPath: audioURL(for: saved.id, paths: paths).path))
    #expect(recorder.isRecording == false)
    #expect(recorder.isBusy == false)
}

@MainActor
@Test("VoiceRecorder keeps audio and retries metadata when final save fails")
func voiceRecorderKeepsAudioAndRetriesMetadataWhenFinalSaveFails() async throws {
    let goodPaths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let blockedRoot = FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerVoiceTests-blocked-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blockedRoot)
    let blockedStore = await LibraryStore.open(paths: LibraryPaths(libraryRoot: blockedRoot, arguments: []))
    let goodStore = await LibraryStore.open(paths: goodPaths)
    let recorder = VoiceRecorder(backend: StubRecordingBackend(
        fixedID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        result: .success(duration: 2, audioData: try validSilentM4AData())
    ))

    await recorder.start(library: goodStore, mode: .micOnly)
    let first = await recorder.finish(library: blockedStore)

    #expect(first == nil)
    #expect(recorder.errorMessage != nil)
    #expect(FileManager.default.fileExists(atPath: audioURL(
        for: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        paths: goodPaths
    ).path))

    recorder.errorMessage = nil
    let retried = await recorder.finish(library: goodStore)

    #expect(retried?.id == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    #expect(goodStore.recording(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!) != nil)
    #expect(recorder.errorMessage == nil)
}

@MainActor
@Test("VoiceRecorder preserves playable audio for retry when finish reports an error")
func voiceRecorderPreservesPlayableAudioForRetryWhenFinishReportsAnError() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    let recorder = VoiceRecorder(backend: StubRecordingBackend(
        fixedID: id,
        result: .writesThenThrows(audioData: try validSilentM4AData(), error: VoiceRecorderError.encoderFailed)
    ))

    await recorder.start(library: store, mode: .micOnly)
    let first = await recorder.finish(library: store)

    #expect(first == nil)
    #expect(recorder.hasPendingRecording == true)
    #expect(FileManager.default.fileExists(atPath: audioURL(for: id, paths: paths).path))

    let retried = await recorder.finish(library: store)

    #expect(retried?.id == id)
    #expect(retried?.warnings.contains("Recovered playable audio after finalization error.") == true)
    #expect(store.recording(id: id) != nil)
}

@MainActor
@Test("VoiceRecorder can defer pending save and recover the audio later")
func voiceRecorderCanDeferPendingSaveAndRecoverTheAudioLater() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let id = UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")!
    let recorder = VoiceRecorder(backend: StubRecordingBackend(
        fixedID: id,
        result: .writesThenThrows(audioData: try validSilentM4AData(), error: VoiceRecorderError.encoderFailed)
    ))

    await recorder.start(library: store, mode: .micOnly)
    let first = await recorder.finish(library: store)
    recorder.deferPendingSave()

    #expect(first == nil)
    #expect(recorder.hasPendingRecording == false)
    #expect(recorder.isBusy == false)
    #expect(FileManager.default.fileExists(atPath: audioURL(for: id, paths: paths).path))

    await recorder.start(library: store, mode: .micOnly)

    #expect(recorder.isRecording == true)
}

@MainActor
@Test("VoiceRecorder recovers readable audio files that lost metadata")
func voiceRecorderRecoversReadableAudioFilesThatLostMetadata() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let recoveredID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
    let ignoredID = UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111")!
    try FileManager.default.createDirectory(at: paths.directory(for: recoveredID), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.directory(for: ignoredID), withIntermediateDirectories: true)
    try validSilentM4AData().write(to: audioURL(for: recoveredID, paths: paths))
    try Data("not audio".utf8).write(to: audioURL(for: ignoredID, paths: paths))
    let recorder = VoiceRecorder()

    let recovered = await recorder.recoverRecordings(library: store)

    #expect(recovered.map(\.id) == [recoveredID])
    #expect(store.recording(id: recoveredID)?.warnings.contains("Recovered finalized audio without metadata.") == true)
    #expect(store.recording(id: ignoredID) == nil)
}

@MainActor
@Test("VoiceRecorder reflects unsupported pause while system capture remains active")
func voiceRecorderReflectsUnsupportedPauseWhileSystemCaptureRemainsActive() async throws {
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: []))
    let recorder = VoiceRecorder(backend: StubRecordingBackend(canPause: false))

    await recorder.start(library: store, mode: .systemOnly)
    recorder.pause()

    #expect(recorder.canPause == false)
    #expect(recorder.isRecording == true)
    #expect(recorder.isPaused == false)
    #expect(recorder.errorMessage != nil)
}

@MainActor
@Test("VoiceRecorder elapsed excludes paused time after resume")
func voiceRecorderElapsedExcludesPausedTimeAfterResume() async throws {
    let clock = StubVoiceClock(now: Date(timeIntervalSince1970: 10))
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: []))
    let recorder = VoiceRecorder(backend: StubRecordingBackend(), clock: clock)

    await recorder.start(library: store, mode: .micOnly)
    clock.now = Date(timeIntervalSince1970: 15)
    recorder.pause()
    clock.now = Date(timeIntervalSince1970: 115)
    recorder.resume()
    clock.now = Date(timeIntervalSince1970: 118)
    recorder.refreshElapsed()

    #expect(recorder.elapsed == 8)
}

@MainActor
@Test("VoiceRecorder forwards optional live audio handler to the backend")
func voiceRecorderForwardsOptionalLiveAudioHandlerToTheBackend() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let backend = StubRecordingBackend()
    let collector = LiveAudioSampleCollector()
    let recorder = VoiceRecorder(backend: backend)
    recorder.liveAudioHandler = collector.append

    await recorder.start(library: store, mode: .micOnly)
    backend.emitConfiguredLiveAudio(samples: [0.3, 0.4], sampleRate: 24_000, startTime: 0.75)
    _ = await recorder.finish(library: store)

    #expect(collector.chunks() == [
        LiveAudioSamples(samples: [0.3, 0.4], sampleRate: 24_000, startTime: 0.75)
    ])
}

@MainActor
@Test("VoiceRecorder saves interrupted recording through the active library")
func voiceRecorderSavesInterruptedRecordingThroughActiveLibrary() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let backend = InterruptingRecordingBackend(result: .success(duration: 3, audioData: try validSilentM4AData()))
    let recorder = VoiceRecorder(backend: backend)

    await recorder.start(library: store, mode: .micOnly)
    await backend.interrupt()

    #expect(store.recordings.count == 1)
    #expect(recorder.isRecording == false)
    #expect(FileManager.default.fileExists(atPath: audioURL(for: store.recordings[0].id, paths: paths).path))
}

@MainActor
@Test("VoicePlayer pauses same recording and replaces different recording")
func voicePlayerPausesSameRecordingAndReplacesDifferentRecording() throws {
    let engine = StubPlaybackEngine()
    let player = VoicePlayer(engine: engine)
    let first = recording(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, duration: 10)
    let second = recording(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, duration: 20)

    try player.play(recording: first, url: URL(filePath: "/tmp/first.m4a"))
    try player.play(recording: first, url: URL(filePath: "/tmp/first.m4a"))
    try player.play(recording: second, url: URL(filePath: "/tmp/second.m4a"))

    #expect(engine.playedIDs == [first.id, second.id])
    #expect(engine.pauseCount == 1)
    #expect(player.recordingID == second.id)
    #expect(player.isPlaying == true)
}

@MainActor
@Test("VoicePlayer ignores stale callbacks after a newer playback starts")
func voicePlayerIgnoresStaleCallbacksAfterANewerPlaybackStarts() throws {
    let engine = StubPlaybackEngine()
    let player = VoicePlayer(engine: engine)
    let first = recording(id: UUID(uuidString: "55555555-6666-7777-8888-999999999999")!, duration: 10)
    let second = recording(id: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!, duration: 20)

    try player.play(recording: first, url: URL(filePath: "/tmp/first.m4a"))
    let staleToken = engine.currentToken
    try player.play(recording: second, url: URL(filePath: "/tmp/second.m4a"))
    engine.finish(successfully: true, token: staleToken)

    #expect(player.recordingID == second.id)
    #expect(player.isPlaying == true)
}

@MainActor
@Test("VoicePlayer records natural completion and decode failures")
func voicePlayerRecordsNaturalCompletionAndDecodeFailures() throws {
    let engine = StubPlaybackEngine()
    let player = VoicePlayer(engine: engine)
    let first = recording(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, duration: 10)

    try player.play(recording: first, url: URL(filePath: "/tmp/first.m4a"))
    engine.finish(successfully: true)

    #expect(player.isPlaying == false)
    #expect(player.currentTime == player.duration)
    #expect(player.errorMessage == nil)

    try player.play(recording: first, url: URL(filePath: "/tmp/first.m4a"))
    engine.finish(successfully: false)

    #expect(player.isPlaying == false)
    #expect(player.errorMessage != nil)
}

private func recording(id: UUID = UUID(), duration: TimeInterval) -> Recording {
    Recording(id: id, title: "Recording", createdAt: Date(timeIntervalSince1970: 100), duration: duration, mode: .micOnly)
}

private func uniqueVoiceLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerVoiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
private final class StubVoiceClock: VoiceClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private func audioURL(for id: UUID, paths: LibraryPaths) -> URL {
    paths.directory(for: id).appending(path: "audio.m4a")
}

private func validSilentM4AData() throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerVoiceTests-fixture-\(UUID().uuidString).m4a")
    do {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ])
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205)!
        buffer.frameLength = 2_205
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
    }
    let data = try Data(contentsOf: url)
    try? FileManager.default.removeItem(at: url)
    return data
}

@MainActor
private final class StubRecordingBackend: VoiceRecordingBackend {
    let fixedID: UUID
    let canPause: Bool
    let result: StubRecordingSession.Result
    private var liveAudioHandler: LiveAudioSampleHandler?

    init(
        fixedID: UUID = UUID(),
        canPause: Bool = true,
        result: StubRecordingSession.Result = .success(duration: 1, audioData: Data("audio".utf8))
    ) {
        self.fixedID = fixedID
        self.canPause = canPause
        self.result = result
    }

    func makeRecordingID() -> UUID {
        fixedID
    }

    func start(
        outputURL: URL,
        mode: CaptureMode,
        liveAudioHandler: LiveAudioSampleHandler?,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> any VoiceRecordingSession {
        self.liveAudioHandler = liveAudioHandler
        return StubRecordingSession(outputURL: outputURL, canPause: canPause, result: result)
    }

    func emitConfiguredLiveAudio(samples: [Float], sampleRate: Double, startTime: Double) {
        liveAudioHandler?(LiveAudioSamples(samples: samples, sampleRate: sampleRate, startTime: startTime))
    }
}

@MainActor
private final class InterruptingRecordingBackend: VoiceRecordingBackend {
    let result: StubRecordingSession.Result
    private var handler: (@MainActor @Sendable () async -> Void)?

    init(result: StubRecordingSession.Result) {
        self.result = result
    }

    func makeRecordingID() -> UUID {
        UUID()
    }

    func start(
        outputURL: URL,
        mode: CaptureMode,
        liveAudioHandler: LiveAudioSampleHandler?,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> any VoiceRecordingSession {
        handler = interruptionHandler
        return StubRecordingSession(outputURL: outputURL, canPause: true, result: result)
    }

    func interrupt() async {
        await handler?()
    }
}

@MainActor
private final class StubRecordingSession: VoiceRecordingSession {
    enum Result {
        case success(duration: TimeInterval, audioData: Data)
        case writesThenThrows(audioData: Data, error: Error)
        case failure(Error)
    }

    let outputURL: URL
    let canPause: Bool
    let result: Result

    init(outputURL: URL, canPause: Bool, result: Result) {
        self.outputURL = outputURL
        self.canPause = canPause
        self.result = result
    }

    func pause() throws {}
    func resume() throws {}

    func finish() async throws -> VoiceRecordingResult {
        switch result {
        case let .success(duration, audioData):
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try audioData.write(to: outputURL)
            return VoiceRecordingResult(duration: duration, warnings: [])
        case let .writesThenThrows(audioData, error):
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try audioData.write(to: outputURL)
            throw error
        case let .failure(error):
            throw error
        }
    }

    func cancel() async {}
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

@MainActor
private final class StubPlaybackEngine: VoicePlaybackEngine {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var playedIDs: [UUID] = []
    var pauseCount = 0
    var finishHandler: (@MainActor @Sendable (Bool, ObjectIdentifier) -> Void)?
    private final class Token {}
    private var token = Token()

    var currentToken: ObjectIdentifier {
        ObjectIdentifier(token)
    }

    var playbackToken: ObjectIdentifier? {
        currentToken
    }

    func play(recording: Recording, url: URL) throws {
        playedIDs.append(recording.id)
        duration = recording.duration
        isPlaying = true
        token = Token()
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        currentTime = time
    }

    func finish(successfully: Bool, token: ObjectIdentifier? = nil) {
        if successfully {
            currentTime = duration
        }
        isPlaying = false
        finishHandler?(successfully, token ?? currentToken)
    }
}
