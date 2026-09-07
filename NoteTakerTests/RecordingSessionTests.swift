import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct RecordingSessionTests {
    @Test("RecordingSession publishes a finished recording only after the engine creates audio")
    func publishesFinishedRecordingOnlyAfterEngineCreatesAudio() async throws {
        let harness = await RecordingSessionHarness.make()
        harness.settings.captureMode = .micAndSystem
        var calls: [String] = []
        harness.player.onStop = { calls.append("player.stop") }
        harness.recorder.onStart = { _ in calls.append("recorder.start") }

        await harness.session.start()

        #expect(calls == ["player.stop", "recorder.start"])
        #expect(harness.session.phase == .recording)
        #expect(harness.store.recordings.isEmpty)
        let request = try #require(harness.recorder.startRequests.first)
        #expect(request.directoryURL == harness.paths.directory(for: request.id))
        #expect(request.mode == .micAndSystem)

        await harness.session.finish()

        let recording = try #require(harness.store.recordings.first)
        #expect(harness.store.recordings.map(\.id) == [recording.id])
        #expect(harness.appModel.selectedRecordingID == recording.id)
        #expect(harness.session.phase == .idle)
        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: recording.id).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.metadataURL(for: recording.id).path))
    }

    @Test("RecordingSession derives elapsed time from a successful start and resets after finish")
    func derivesElapsedTimeFromSuccessfulStartAndResetsAfterFinish() async throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let harness = await RecordingSessionHarness.make(now: { startedAt })

        await harness.session.start()

        #expect(harness.session.phase == .recording)
        #expect(harness.session.elapsed(at: startedAt.addingTimeInterval(3.5)) == 3.5)

        await harness.session.finish()

        #expect(harness.session.phase == .idle)
        #expect(harness.session.elapsed(at: startedAt.addingTimeInterval(3.5)) == 0)
    }

    @Test("RecordingSession pause loads preview and freezes elapsed until resume")
    func pauseLoadsPreviewAndFreezesElapsedUntilResume() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let harness = await RecordingSessionHarness.make(now: { currentDate })

        await harness.session.start()
        currentDate = currentDate.addingTimeInterval(4)
        await harness.session.pause()

        #expect(harness.session.phase == .paused)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(30)) == 4)
        #expect(harness.recorder.pauseCallCount == 1)
        #expect(harness.player.loadedURLs.last?.lastPathComponent == "preview.m4a")

        currentDate = currentDate.addingTimeInterval(20)
        await harness.session.resume()

        #expect(harness.session.phase == .recording)
        #expect(harness.recorder.resumeCallCount == 1)
        #expect(harness.player.stopCallCount == 2)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(3)) == 7)
    }

    @Test("RecordingSession remains paused and finishable when preview load fails")
    func remainsPausedAndFinishableWhenPreviewLoadFails() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 2_000)
        let harness = await RecordingSessionHarness.make(now: { currentDate })
        harness.player.loadError = PlayerEngineError.failed("Preview failed")

        await harness.session.start()
        currentDate = currentDate.addingTimeInterval(5)
        await harness.session.pause()

        #expect(harness.session.phase == .paused)
        #expect(harness.session.alert?.message == "Preview failed")
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(20)) == 5)

        await harness.session.finish()

        #expect(harness.session.phase == .idle)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.recorder.stopCallCount == 1)
        #expect(harness.recorder.confirmPublishedCallCount == 1)
    }

    @Test("RecordingSession remains pausing until preview load settles and ignores resume finish races")
    func remainsPausingUntilPreviewLoadSettlesAndIgnoresResumeFinishRaces() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 2_500)
        let previewLoader = ControlledPreviewLoader()
        let harness = await RecordingSessionHarness.make(
            loadPreview: previewLoader.load(url:duration:),
            now: { currentDate }
        )

        await harness.session.start()
        currentDate = currentDate.addingTimeInterval(5)
        let pauseTask = Task {
            await harness.session.pause()
        }
        await waitForRecordingSessionState { previewLoader.pendingLoadCount == 1 }

        async let resumeWhilePausing: Void = harness.session.resume()
        async let finishWhilePausing: Void = harness.session.finish()
        _ = await (resumeWhilePausing, finishWhilePausing)

        #expect(harness.session.phase == .pausing)
        #expect(harness.recorder.resumeCallCount == 0)
        #expect(harness.recorder.stopCallCount == 0)

        previewLoader.completeOldestLoad()
        await pauseTask.value

        #expect(harness.session.phase == .paused)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(20)) == 5)

        await harness.session.finish()

        #expect(harness.session.phase == .idle)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.recorder.stopCallCount == 1)
    }

    @Test("RecordingSession termination finish waits for transitions and blocks new starts")
    func terminationFinishWaitsForTransitionsAndBlocksNewStarts() async throws {
        let previewLoader = ControlledPreviewLoader()
        let harness = await RecordingSessionHarness.make(loadPreview: previewLoader.load(url:duration:))

        await harness.session.start()
        let pauseTask = Task {
            await harness.session.pause()
        }
        await waitForRecordingSessionState { previewLoader.pendingLoadCount == 1 }

        let terminationTask = Task {
            await harness.session.finishForTermination()
        }
        await allowRecordingSessionTasksToRun()
        await harness.session.start()

        #expect(harness.recorder.startRequests.count == 1)
        #expect(harness.session.phase == .pausing)

        previewLoader.completeOldestLoad()
        await pauseTask.value
        await terminationTask.value

        #expect(harness.session.phase == .idle)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.recorder.stopCallCount == 1)
    }

    @Test("RecordingSession tracks scoped recorder progress levels and resets them after finish")
    func tracksScopedRecorderProgressLevelsAndResetsAfterFinish() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 4_000)
        let harness = await RecordingSessionHarness.make(now: { currentDate })

        await harness.session.start()
        let request = try #require(harness.recorder.startRequests.first)
        currentDate = currentDate.addingTimeInterval(1)
        harness.recorder.emitProgress(
            recordingID: request.id,
            duration: 3.25,
            microphonePeak: 0.4,
            systemPeak: 0.7
        )
        await waitForRecordingSessionState {
            harness.session.microphonePeak == 0.4
                && harness.session.systemPeak == 0.7
        }

        #expect(harness.session.microphonePeak == 0.4)
        #expect(harness.session.systemPeak == 0.7)
        #expect(harness.session.elapsed(at: currentDate) == 3.25)

        harness.recorder.emitProgress(
            recordingID: UUID(),
            duration: 12,
            microphonePeak: 1,
            systemPeak: 1
        )
        await allowRecordingSessionTasksToRun()

        #expect(harness.session.microphonePeak == 0.4)
        #expect(harness.session.systemPeak == 0.7)

        await harness.session.finish()

        #expect(harness.session.microphonePeak == 0)
        #expect(harness.session.systemPeak == 0)
        #expect(harness.session.elapsed(at: Date()) == 0)
    }

    @Test("RecordingSession ignores stale pause continuation after terminal failure")
    func ignoresStalePauseContinuationAfterTerminalFailure() async throws {
        let harness = await GatedRecordingSessionHarness.make()
        let recorder = harness.recorder

        await harness.session.start()
        let firstRequest = try #require(recorder.startRequests.first)
        recorder.gatePause = true
        let pauseTask = Task {
            await harness.session.pause()
        }
        await waitForRecordingSessionState { recorder.pendingPauseCount == 1 }

        recorder.fail(message: "Device disconnected.", keepsPartialFile: true)
        await waitForRecordingSessionState { harness.session.phase == .idle }
        #expect(harness.session.alert?.message == "Device disconnected.")
        await harness.session.start()
        let secondRequest = try #require(recorder.startRequests.last)

        recorder.completePause()
        await pauseTask.value

        #expect(firstRequest.id != secondRequest.id)
        #expect(harness.session.phase == .recording)
        #expect(harness.session.alert == nil)
        #expect(harness.store.recordings.isEmpty)
    }

    @Test("RecordingSession ignores stale resume continuation after terminal failure")
    func ignoresStaleResumeContinuationAfterTerminalFailure() async throws {
        let harness = await GatedRecordingSessionHarness.make()
        let recorder = harness.recorder

        await harness.session.start()
        await harness.session.pause()
        recorder.gateResume = true
        let resumeTask = Task {
            await harness.session.resume()
        }
        await waitForRecordingSessionState { recorder.pendingResumeCount == 1 }

        recorder.fail(message: "Device disconnected.", keepsPartialFile: true)
        await waitForRecordingSessionState { harness.session.phase == .idle }
        #expect(harness.session.alert?.message == "Device disconnected.")
        await harness.session.start()

        recorder.completeResume()
        await resumeTask.value

        #expect(harness.session.phase == .recording)
        #expect(harness.session.alert == nil)
        #expect(harness.store.recordings.isEmpty)
        let secondRequest = try #require(recorder.startRequests.last)
        await harness.session.finish()
        #expect(harness.store.recordings.map(\.id) == [secondRequest.id])
        #expect(harness.session.alert == nil)
    }

    @Test("RecordingSession ignores stale finish continuation after terminal failure")
    func ignoresStaleFinishContinuationAfterTerminalFailure() async throws {
        let harness = await GatedRecordingSessionHarness.make()
        let recorder = harness.recorder

        await harness.session.start()
        recorder.gateStop = true
        let finishTask = Task {
            await harness.session.finish()
        }
        await waitForRecordingSessionState { recorder.pendingStopCount == 1 }

        recorder.fail(message: "Device disconnected.", keepsPartialFile: true)
        await waitForRecordingSessionState { harness.session.phase == .idle }
        #expect(harness.session.alert?.message == "Device disconnected.")
        await harness.session.start()
        let secondRequest = try #require(recorder.startRequests.last)

        recorder.completeStop()
        await finishTask.value

        #expect(harness.session.phase == .recording)
        #expect(harness.session.alert == nil)
        #expect(harness.appModel.selectedRecordingID == nil)
        #expect(harness.store.recordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: secondRequest.id).path))
    }

    @Test("RecordingSession remains paused and resumable when preview load fails")
    func remainsPausedAndResumableWhenPreviewLoadFails() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 3_000)
        let harness = await RecordingSessionHarness.make(now: { currentDate })
        harness.player.loadError = PlayerEngineError.failed("Preview failed")

        await harness.session.start()
        currentDate = currentDate.addingTimeInterval(6)
        await harness.session.pause()
        harness.player.loadError = nil
        currentDate = currentDate.addingTimeInterval(30)
        await harness.session.resume()

        #expect(harness.session.phase == .recording)
        #expect(harness.recorder.resumeCallCount == 1)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(4)) == 10)
    }

    @Test("RecordingSession does not keep elapsed state from a failed start")
    func doesNotKeepElapsedStateFromFailedStart() async throws {
        var currentDate = Date(timeIntervalSinceReferenceDate: 200)
        let harness = await RecordingSessionHarness.make(now: { currentDate })
        harness.recorder.startError = RecorderEngineError.failed(
            message: "First start failed",
            settingsURL: nil,
            keepsPartialFile: false
        )

        await harness.session.start()

        #expect(harness.session.phase == .idle)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(8)) == 0)

        harness.recorder.startError = nil
        currentDate = Date(timeIntervalSinceReferenceDate: 500)
        await harness.session.start()

        #expect(harness.session.phase == .recording)
        #expect(harness.session.elapsed(at: currentDate.addingTimeInterval(2)) == 2)
    }

    @Test("RecordingSession finishes once when completion is tapped twice")
    func finishesOnceWhenCompletionIsTappedTwice() async throws {
        let harness = await RecordingSessionHarness.make()
        await harness.session.start()

        async let first: Void = harness.session.finish()
        async let second: Void = harness.session.finish()
        _ = await (first, second)

        #expect(harness.recorder.stopCallCount == 1)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.session.phase == .idle)
        #expect(harness.recorder.confirmPublishedCallCount == 1)
    }

    @Test("RecordingSession start failure removes an empty owned directory and returns idle")
    func startFailureRemovesEmptyOwnedDirectoryAndReturnsIdle() async throws {
        let harness = await RecordingSessionHarness.make()
        harness.recorder.startError = RecorderEngineError.permissionDenied(message: "Microphone access is required", settingsURL: nil)

        await harness.session.start()

        let request = try #require(harness.recorder.startRequests.first)
        #expect(harness.session.phase == .idle)
        #expect(harness.session.alert?.message == "Microphone access is required")
        #expect(harness.store.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.directory(for: request.id).path))
    }

    @Test("RecordingSession stop failure keeps playable partial audio without publishing a row")
    func stopFailureKeepsPlayablePartialAudioWithoutPublishingRow() async throws {
        let harness = await RecordingSessionHarness.make()
        harness.recorder.stopError = RecorderEngineError.failed(message: "Could not finish recording", settingsURL: nil, keepsPartialFile: true)
        await harness.session.start()
        let request = try #require(harness.recorder.startRequests.first)

        await harness.session.finish()

        #expect(harness.session.phase == .idle)
        #expect(harness.session.alert?.message == "Could not finish recording")
        #expect(harness.session.alert?.displayMessage == "Could not finish recording\n\n\(String(localized: "Your partial recording file was kept. You can retry finishing or recover it on the next launch."))")
        #expect(harness.store.recordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: request.id).path))
    }

    @Test("RecordingSession rejects a foreign finished URL without publishing metadata")
    func rejectsForeignFinishedURLWithoutPublishingMetadata() async throws {
        let harness = await RecordingSessionHarness.make()
        let foreignURL = uniqueLibraryRoot()
            .appending(path: "foreign-audio.m4a")
        try FileManager.default.createDirectory(
            at: foreignURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: foreignURL)
        harness.recorder.resultURL = foreignURL

        await harness.session.start()
        let request = try #require(harness.recorder.startRequests.first)
        await harness.session.finish()

        #expect(harness.session.phase == .idle)
        #expect(harness.store.recordings.isEmpty)
        #expect(harness.appModel.selectedRecordingID == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.metadataURL(for: request.id).path))
        #expect(FileManager.default.fileExists(atPath: foreignURL.path))
    }

    @Test("RecordingSession can retry after a failed start")
    func canRetryAfterAFailedStart() async throws {
        let harness = await RecordingSessionHarness.make()
        harness.recorder.startError = RecorderEngineError.failed(message: "First start failed", settingsURL: nil, keepsPartialFile: false)

        await harness.session.start()
        harness.recorder.startError = nil
        await harness.session.start()
        await harness.session.finish()

        #expect(harness.recorder.startRequests.count == 2)
        #expect(harness.store.recordings.count == 1)
        #expect(harness.session.phase == .idle)
    }

    @Test("RecordingSession ignores buffered failed start events after retry")
    func ignoresBufferedFailedStartEventsAfterRetry() async throws {
        let harness = await RecordingSessionHarness.make()
        harness.recorder.startError = RecorderEngineError.failed(message: "First start failed", settingsURL: nil, keepsPartialFile: false)

        await harness.session.start()
        let firstRequest = try #require(harness.recorder.startRequests.first)
        harness.recorder.emitFailure(
            recordingID: firstRequest.id,
            message: "Late first-start failure",
            keepsPartialFile: false
        )
        harness.recorder.startError = nil

        await harness.session.start()
        let secondRequest = try #require(harness.recorder.startRequests.last)
        await allowRecordingSessionTasksToRun()

        #expect(secondRequest.id != firstRequest.id)
        #expect(harness.session.phase == .recording)
        #expect(harness.session.alert == nil)
    }

    @Test("RecordingSession alert display message explains retained partial files only when present")
    func alertDisplayMessageExplainsRetainedPartialFilesOnlyWhenPresent() {
        let retained = RecordingSessionAlert(
            message: "Could not finish recording",
            settingsURL: nil,
            keepsPartialFile: true
        )
        let discarded = RecordingSessionAlert(
            message: "Could not start recording",
            settingsURL: nil,
            keepsPartialFile: false
        )

        #expect(retained.displayMessage == "Could not finish recording\n\n\(String(localized: "Your partial recording file was kept. You can retry finishing or recover it on the next launch."))")
        #expect(discarded.displayMessage == "Could not start recording")
    }

    @Test("RecordingSession unlocks controls for runtime failures and ignores stale events after retry")
    func unlocksControlsForRuntimeFailuresAndIgnoresStaleEventsAfterRetry() async throws {
        let harness = await RecordingSessionHarness.make()
        await harness.session.start()
        let firstRequest = try #require(harness.recorder.startRequests.first)

        harness.recorder.fail(message: "A recording device was disconnected.", keepsPartialFile: true)
        await waitForRecordingSessionState { harness.session.phase == .idle }

        #expect(harness.session.phase == .idle)
        #expect(harness.session.alert?.message == "A recording device was disconnected.")
        #expect(harness.session.alert?.settingsURL == nil)
        #expect(harness.session.alert?.keepsPartialFile == true)
        #expect(harness.store.recordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: firstRequest.id).path))

        await harness.session.start()
        let secondRequest = try #require(harness.recorder.startRequests.last)
        #expect(secondRequest.id != firstRequest.id)
        #expect(harness.session.phase == .recording)

        harness.recorder.emitStaleFailure(message: "Old device failure", keepsPartialFile: true)
        await allowRecordingSessionTasksToRun()

        #expect(harness.session.phase == .recording)
        #expect(harness.session.alert == nil)
    }
}

@MainActor
private struct RecordingSessionHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let recorder: FakeRecorderEngine
    let player: FakePlayerEngine
    let appModel: AppModel
    let settings: AppSettings
    let session: RecordingSession

    static func make(
        loadPreview: (((URL, TimeInterval) async throws -> Void))? = nil,
        now: @escaping () -> Date = Date.init
    ) async -> RecordingSessionHarness {
        let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let recorder = FakeRecorderEngine()
        let player = FakePlayerEngine()
        let appModel = AppModel()
        let settings = AppSettings(defaults: isolatedDefaults())
        let session = RecordingSession(
            recorder: recorder,
            player: player,
            library: store,
            appModel: appModel,
            settings: settings,
            loadPreview: loadPreview,
            now: now
        )
        return RecordingSessionHarness(
            paths: paths,
            store: store,
            recorder: recorder,
            player: player,
            appModel: appModel,
            settings: settings,
            session: session
        )
    }
}

@MainActor
private struct GatedRecordingSessionHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let recorder: GatedRecorderEngine
    let player: FakePlayerEngine
    let appModel: AppModel
    let settings: AppSettings
    let session: RecordingSession

    static func make(now: @escaping () -> Date = Date.init) async -> GatedRecordingSessionHarness {
        let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let recorder = GatedRecorderEngine()
        let player = FakePlayerEngine()
        let appModel = AppModel()
        let settings = AppSettings(defaults: isolatedDefaults())
        let session = RecordingSession(
            recorder: recorder,
            player: player,
            library: store,
            appModel: appModel,
            settings: settings,
            now: now
        )
        return GatedRecordingSessionHarness(
            paths: paths,
            store: store,
            recorder: recorder,
            player: player,
            appModel: appModel,
            settings: settings,
            session: session
        )
    }
}

@MainActor
private final class GatedRecorderEngine: RecorderEngine {
    private struct PendingPause {
        let request: RecorderRequest
        let continuation: CheckedContinuation<RecorderPreview, any Error>
    }

    private struct PendingStop {
        let request: RecorderRequest
        let continuation: CheckedContinuation<RecorderResult, any Error>
    }

    private(set) var state: RecorderState = .idle
    private(set) var startRequests: [RecorderRequest] = []
    private(set) var stopCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var confirmPublishedCallCount = 0
    var gatePause = false
    var gateResume = false
    var gateStop = false

    private var pendingPauseContinuations: [PendingPause] = []
    private var pendingResumeContinuations: [CheckedContinuation<Void, any Error>] = []
    private var pendingStopContinuations: [PendingStop] = []
    private let stream: AsyncStream<RecorderEvent>
    private let continuation: AsyncStream<RecorderEvent>.Continuation

    var events: AsyncStream<RecorderEvent> { stream }
    var pendingPauseCount: Int { pendingPauseContinuations.count }
    var pendingResumeCount: Int { pendingResumeContinuations.count }
    var pendingStopCount: Int { pendingStopContinuations.count }

    init() {
        var capturedContinuation: AsyncStream<RecorderEvent>.Continuation!
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func start(_ request: RecorderRequest) async throws -> RecorderStart {
        startRequests.append(request)
        try FileManager.default.createDirectory(at: request.directoryURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: request.directoryURL.appending(path: "audio.m4a"))
        state = .recording
        return RecorderStart(warnings: [])
    }

    func pause() async throws -> RecorderPreview {
        pauseCallCount += 1
        let request = try currentRequest()
        if gatePause {
            return try await withCheckedThrowingContinuation { continuation in
                pendingPauseContinuations.append(PendingPause(
                    request: request,
                    continuation: continuation
                ))
            }
        }
        state = .paused
        return try preview(for: request)
    }

    func completePause() {
        guard !pendingPauseContinuations.isEmpty else { return }
        let pendingPause = pendingPauseContinuations.removeFirst()
        state = .paused
        do {
            let preview = try preview(for: pendingPause.request)
            pendingPause.continuation.resume(returning: preview)
        } catch {
            pendingPause.continuation.resume(throwing: error)
        }
    }

    func resume() async throws {
        resumeCallCount += 1
        if gateResume {
            try await withCheckedThrowingContinuation { continuation in
                pendingResumeContinuations.append(continuation)
            }
            return
        }
        state = .recording
    }

    func completeResume() {
        guard !pendingResumeContinuations.isEmpty else { return }
        state = .recording
        pendingResumeContinuations.removeFirst().resume()
    }

    func stop() async throws -> RecorderResult {
        stopCallCount += 1
        let request = try currentRequest()
        if gateStop {
            return try await withCheckedThrowingContinuation { continuation in
                pendingStopContinuations.append(PendingStop(
                    request: request,
                    continuation: continuation
                ))
            }
        }
        state = .stopped
        return try result(for: request)
    }

    func completeStop() {
        guard !pendingStopContinuations.isEmpty else { return }
        let pendingStop = pendingStopContinuations.removeFirst()
        state = .stopped
        do {
            let output = try result(for: pendingStop.request)
            pendingStop.continuation.resume(returning: output)
        } catch {
            pendingStop.continuation.resume(throwing: error)
        }
    }

    func confirmPublished() async {
        confirmPublishedCallCount += 1
    }

    func fail(message: String, settingsURL: URL? = nil, keepsPartialFile: Bool) {
        guard let recordingID = startRequests.last?.id else { return }
        state = .idle
        continuation.yield(.recordingFailed(
            recordingID: recordingID,
            message: message,
            settingsURL: settingsURL,
            keepsPartialFile: keepsPartialFile
        ))
    }

    private func currentRequest() throws -> RecorderRequest {
        guard let request = startRequests.last else {
            throw RecorderEngineError.failed(message: "Recording has not started", settingsURL: nil, keepsPartialFile: false)
        }
        return request
    }

    private func preview(for request: RecorderRequest) throws -> RecorderPreview {
        let previewURL = request.directoryURL
            .appending(path: "segments", directoryHint: .isDirectory)
            .appending(path: "preview.m4a")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preview".utf8).write(to: previewURL)
        return RecorderPreview(url: previewURL, duration: 1)
    }

    private func result(for request: RecorderRequest) throws -> RecorderResult {
        return RecorderResult(
            url: request.directoryURL.appending(path: "audio.m4a"),
            duration: 1,
            warnings: []
        )
    }
}

@MainActor
private final class ControlledPreviewLoader {
    private var pendingLoads: [CheckedContinuation<Void, any Error>] = []

    var pendingLoadCount: Int { pendingLoads.count }

    func load(url: URL, duration: TimeInterval) async throws {
        _ = url
        _ = duration
        try await withCheckedThrowingContinuation { continuation in
            pendingLoads.append(continuation)
        }
    }

    func completeOldestLoad() {
        guard !pendingLoads.isEmpty else { return }
        pendingLoads.removeFirst().resume()
    }
}

private func uniqueLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerRecordingSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "NoteTakerRecordingSessionTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func allowRecordingSessionTasksToRun() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
private func waitForRecordingSessionState(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        await Task.yield()
    }
}
