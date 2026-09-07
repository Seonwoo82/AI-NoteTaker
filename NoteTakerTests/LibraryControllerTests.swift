import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct LibraryControllerTests {
    @Test("folder selection composes counts search and keeps a visible selected row")
    func folderSelectionComposesCountsSearchAndKeepsVisibleSelection() async throws {
        let harness = await LibraryControllerHarness.make()
        let ordinary = try await harness.addRecording(title: "Budget Review", createdAt: Date(timeIntervalSince1970: 300))
        let favorite = try await harness.addRecording(title: "Design Budget", createdAt: Date(timeIntervalSince1970: 200), isFavorite: true)
        let deleted = try await harness.addRecording(title: "Deleted Budget", createdAt: Date(timeIntervalSince1970: 100), deletedAt: referenceDate)
        harness.model.selectedRecordingID = ordinary.id

        await harness.controller.selectFolder(.favorites)
        harness.controller.setSearchText(" budget ")

        #expect(harness.controller.count(for: .all) == 2)
        #expect(harness.controller.count(for: .favorites) == 1)
        #expect(harness.controller.count(for: .recentlyDeleted) == 1)
        #expect(harness.controller.visibleRecordings.map(\.id) == [favorite.id])
        #expect(harness.model.selectedRecordingID == favorite.id)

        await harness.controller.selectFolder(.recentlyDeleted)
        #expect(harness.controller.visibleRecordings.map(\.id) == [deleted.id])
        #expect(harness.model.selectedRecordingID == deleted.id)
    }

    @Test("empty folder clears stale selection and stops playback")
    func emptyFolderClearsStaleSelectionAndStopsPlayback() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Only", isFavorite: false)
        harness.model.selectedRecordingID = recording.id
        try await harness.playback.load(recording: recording)
        await harness.playback.play()

        await harness.controller.selectFolder(.favorites)

        #expect(harness.controller.visibleRecordings.isEmpty)
        #expect(harness.model.selectedRecordingID == nil)
        #expect(!harness.playback.isPlaying)
        #expect(harness.player.stopCallCount == 1)
    }

    @Test("selected soft delete stops playback and selects the next visible row")
    func selectedSoftDeleteStopsPlaybackAndSelectsNextVisibleRow() async throws {
        let harness = await LibraryControllerHarness.make()
        let newest = try await harness.addRecording(title: "Newest", createdAt: Date(timeIntervalSince1970: 300))
        let next = try await harness.addRecording(title: "Next", createdAt: Date(timeIntervalSince1970: 200))
        _ = try await harness.addRecording(title: "Deleted", createdAt: Date(timeIntervalSince1970: 100), deletedAt: referenceDate)
        harness.model.selectedRecordingID = newest.id
        try await harness.playback.load(recording: newest)
        await harness.playback.play()

        try await harness.controller.moveToRecentlyDeleted(newest.id)

        #expect(harness.store.recording(id: newest.id)?.deletedAt != nil)
        #expect(harness.model.selectedRecordingID == next.id)
        #expect(!harness.playback.isPlaying)
    }

    @Test("library mutations are blocked during active capture")
    func libraryMutationsAreBlockedDuringActiveCapture() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Locked")
        await harness.session.start()

        do {
            try await harness.controller.rename(recording.id, to: "Changed")
            Issue.record("Expected active recording rename to throw")
        } catch let error as LibraryControllerError {
            #expect(error == .captureActive)
        } catch {
            Issue.record("Expected LibraryControllerError, got \(error)")
        }

        #expect(harness.store.recording(id: recording.id)?.title == "Locked")
    }

    @Test("search focus requests do not latch editing state and keyboard start stays guarded")
    func searchFocusRequestsDoNotLatchEditingStateAndKeyboardStartStaysGuarded() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Search Result")
        harness.model.selectedRecordingID = recording.id
        harness.model.selectedFolder = .favorites
        harness.controller.setSearchText("result")

        harness.controller.requestSearchFocus()

        #expect(harness.model.searchFocusRequestID == 1)
        #expect(!harness.model.isEditingText)

        harness.model.isEditingText = true
        await harness.controller.startNewRecordingFromKeyboard()

        #expect(harness.session.phase == .idle)
        #expect(harness.model.selectedFolder == .favorites)
        #expect(harness.model.searchText == "result")
        #expect(harness.model.selectedRecordingID == recording.id)

        await harness.controller.startNewRecording()

        #expect(harness.session.phase == .recording)
        #expect(harness.model.selectedFolder == .all)
        #expect(harness.model.searchText.isEmpty)
        #expect(harness.model.searchBlurRequestID == 1)
        #expect(harness.model.selectedRecordingID == nil)
        #expect(!harness.model.isEditingText)
    }

    @Test("permanent delete requires explicit confirmation and cancel preserves audio")
    func permanentDeleteRequiresExplicitConfirmationAndCancelPreservesAudio() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Trash", deletedAt: referenceDate)

        harness.controller.requestPermanentDelete(recording.id)
        harness.controller.cancelPermanentDelete()

        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: recording.id).path))
        #expect(harness.store.recording(id: recording.id)?.id == recording.id)

        harness.controller.requestPermanentDelete(recording.id)
        try await harness.controller.confirmPermanentDelete()

        #expect(!FileManager.default.fileExists(atPath: harness.paths.audioURL(for: recording.id).path))
        #expect(harness.store.recording(id: recording.id) == nil)
    }

    @Test("permanent delete stops playback before removing files and preserves newer selection")
    func permanentDeleteStopsPlaybackBeforeRemovingFilesAndPreservesNewerSelection() async throws {
        let harness = await ControlledStopLibraryControllerHarness.make()
        let deleted = try await harness.addRecording(title: "Trash", deletedAt: referenceDate)
        let next = try await harness.addRecording(title: "Next")
        harness.model.selectedRecordingID = deleted.id
        try await harness.playback.load(recording: deleted)
        await harness.playback.play()

        let deleteTask = Task {
            try? await harness.controller.confirmPermanentDelete(deleted.id)
        }
        await waitForLibraryControllerCondition { harness.player.pendingStopCount == 1 }

        #expect(FileManager.default.fileExists(atPath: harness.paths.audioURL(for: deleted.id).path))
        #expect(harness.store.recording(id: deleted.id)?.id == deleted.id)

        harness.model.selectedRecordingID = next.id
        await harness.controller.startNewRecording()
        harness.player.completeOldestStop()
        await deleteTask.value

        #expect(!FileManager.default.fileExists(atPath: harness.paths.audioURL(for: deleted.id).path))
        #expect(harness.store.recording(id: deleted.id) == nil)
        #expect(harness.model.selectedRecordingID == next.id)
        #expect(harness.session.phase == .idle)
    }

    @Test("confirmed permanent delete survives dialog dismissal before async continuation")
    func confirmedPermanentDeleteSurvivesDialogDismissalBeforeAsyncContinuation() async throws {
        let harness = await ControlledStopLibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Trash", deletedAt: referenceDate)
        harness.model.selectedRecordingID = recording.id
        try await harness.playback.load(recording: recording)

        harness.controller.requestPermanentDelete(recording.id)
        let deleteTask = Task {
            try? await harness.controller.confirmPermanentDelete(recording.id)
        }
        await waitForLibraryControllerCondition { harness.player.pendingStopCount == 1 }
        harness.controller.cancelPermanentDelete()

        #expect(harness.store.recording(id: recording.id)?.id == recording.id)

        harness.player.completeOldestStop()
        await deleteTask.value

        #expect(harness.store.recording(id: recording.id) == nil)
    }

    @Test("rename failure retains draft and original item")
    func renameFailureRetainsDraftAndOriginalItem() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Original")
        harness.controller.beginRename(recording.id)
        harness.controller.renameDraft = "Draft"
        try FileManager.default.removeItem(at: harness.paths.metadataURL(for: recording.id))
        try FileManager.default.createDirectory(at: harness.paths.metadataURL(for: recording.id), withIntermediateDirectories: true)

        do {
            try await harness.controller.commitRename()
            Issue.record("Expected failed rename to throw")
        } catch {
            #expect(harness.controller.renamingRecordingID == recording.id)
            #expect(harness.controller.renameDraft == "Draft")
            #expect(harness.store.recording(id: recording.id)?.title == "Original")
        }
    }

    @Test("restore persists and reveals restored item in all recordings")
    func restorePersistsAndRevealsRestoredItem() async throws {
        let harness = await LibraryControllerHarness.make()
        let recording = try await harness.addRecording(title: "Restorable", deletedAt: referenceDate)
        await harness.controller.selectFolder(.recentlyDeleted)

        try await harness.controller.restore(recording.id)

        #expect(harness.model.selectedFolder == .all)
        #expect(harness.model.selectedRecordingID == recording.id)
        let reopened = await LibraryStore.open(paths: harness.paths, now: referenceDate)
        #expect(reopened.recording(id: recording.id)?.deletedAt == nil)
    }
}

@MainActor
private struct LibraryControllerHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let model: AppModel
    let settings: AppSettings
    let recorder: FakeRecorderEngine
    let player: FakePlayerEngine
    let playback: PlaybackController
    let session: RecordingSession
    let controller: LibraryController

    static func make() async -> LibraryControllerHarness {
        let paths = LibraryPaths(libraryRoot: uniqueLibraryControllerRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let model = AppModel()
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "LibraryControllerTests-\(UUID().uuidString)")!,
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
        )
        let recorder = FakeRecorderEngine()
        let player = FakePlayerEngine()
        let playback = PlaybackController(player: player, library: store)
        let session = RecordingSession(
            recorder: recorder,
            player: player,
            library: store,
            appModel: model,
            settings: settings,
            stopPlayback: {
                await playback.stop()
            },
            loadPreview: { url, duration in
                try await playback.loadPreview(url: url, duration: duration)
            },
            now: { referenceDate }
        )
        let controller = LibraryController(
            library: store,
            model: model,
            session: session,
            playback: playback
        )
        return LibraryControllerHarness(
            paths: paths,
            store: store,
            model: model,
            settings: settings,
            recorder: recorder,
            player: player,
            playback: playback,
            session: session,
            controller: controller
        )
    }

    func addRecording(
        title: String,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        isFavorite: Bool = false,
        deletedAt: Date? = nil
    ) async throws -> Recording {
        let recording = Recording(
            title: title,
            createdAt: createdAt,
            duration: 10,
            mode: .micAndSystem,
            isFavorite: isFavorite,
            deletedAt: deletedAt
        )
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
        try store.add(recording)
        return recording
    }
}

@MainActor
private struct ControlledStopLibraryControllerHarness {
    let paths: LibraryPaths
    let store: LibraryStore
    let model: AppModel
    let player: ControlledStopPlayerEngine
    let playback: PlaybackController
    let session: RecordingSession
    let controller: LibraryController

    static func make() async -> ControlledStopLibraryControllerHarness {
        let paths = LibraryPaths(libraryRoot: uniqueLibraryControllerRoot(), arguments: [])
        let store = await LibraryStore.open(paths: paths)
        let model = AppModel()
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "LibraryControllerTests-\(UUID().uuidString)")!,
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
        )
        let player = ControlledStopPlayerEngine()
        let playback = PlaybackController(player: player, library: store)
        let session = RecordingSession(
            recorder: FakeRecorderEngine(),
            player: player,
            library: store,
            appModel: model,
            settings: settings,
            stopPlayback: {
                await playback.stop()
            },
            loadPreview: { url, duration in
                try await playback.loadPreview(url: url, duration: duration)
            },
            now: { referenceDate }
        )
        let controller = LibraryController(
            library: store,
            model: model,
            session: session,
            playback: playback
        )
        return ControlledStopLibraryControllerHarness(
            paths: paths,
            store: store,
            model: model,
            player: player,
            playback: playback,
            session: session,
            controller: controller
        )
    }

    func addRecording(
        title: String,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        deletedAt: Date? = nil
    ) async throws -> Recording {
        let recording = Recording(
            title: title,
            createdAt: createdAt,
            duration: 10,
            mode: .micAndSystem,
            deletedAt: deletedAt
        )
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
        try store.add(recording)
        return recording
    }
}

@MainActor
private final class ControlledStopPlayerEngine: PlayerEngine {
    private struct PendingStop {
        let continuation: CheckedContinuation<Void, Never>
    }

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    private(set) var loadedURLs: [URL] = []
    private var pendingStops: [PendingStop] = []
    private var finishHandler: (@MainActor () -> Void)?

    var pendingStopCount: Int { pendingStops.count }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        finishHandler = handler
    }

    func load(url: URL) async throws {
        loadedURLs.append(url)
        currentTime = 0
        duration = 10
    }

    func play() async throws {
        isPlaying = true
    }

    func pause() async {
        isPlaying = false
    }

    func seek(to time: TimeInterval) async {
        currentTime = time
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            pendingStops.append(PendingStop(continuation: continuation))
        }
        isPlaying = false
        currentTime = 0
    }

    func completeOldestStop() {
        guard !pendingStops.isEmpty else { return }
        let stop = pendingStops.removeFirst()
        stop.continuation.resume()
    }
}

private let referenceDate = Date(timeIntervalSince1970: 1_000_000)

private func uniqueLibraryControllerRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerLibraryControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
private func waitForLibraryControllerCondition(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() {
            return
        }
        await Task.yield()
    }
}
