import Foundation
import Observation

nonisolated enum LibraryControllerError: Error, Equatable, Sendable {
    case captureActive
    case missingSelection
}

nonisolated struct RecordingRenameSession: Identifiable, Equatable {
    enum Location { case sidebar, detail }
    let id = UUID()
    let recordingID: UUID
    let location: Location
}

@MainActor
@Observable
final class LibraryController {
    let library: LibraryStore
    let model: AppModel
    private let session: RecordingSession
    private let playback: PlaybackController

    private(set) var renameSession: RecordingRenameSession?
    var renamingRecordingID: UUID? { renameSession?.recordingID }
    var renameDraft = ""
    var pendingPermanentDeleteID: UUID?
    private(set) var errorMessage: String?
    private var isPermanentlyDeleting = false

    init(
        library: LibraryStore,
        model: AppModel,
        session: RecordingSession,
        playback: PlaybackController
    ) {
        self.library = library
        self.model = model
        self.session = session
        self.playback = playback
    }

    var visibleRecordings: [Recording] {
        library.filteredRecordings(in: model.selectedFolder, matching: model.searchText)
    }

    var selectedRecording: Recording? {
        guard let id = model.selectedRecordingID else { return nil }
        return library.recording(id: id)
    }

    func count(for folder: RecordingFolder) -> Int {
        library.filteredRecordings(in: folder).count
    }

    func setSearchText(_ text: String) {
        model.searchText = text
        Task { await reconcileSelectionWithVisibleRows() }
    }

    func selectFolder(_ folder: RecordingFolder) async {
        model.selectedFolder = folder
        await reconcileSelectionWithVisibleRows()
    }

    func selectRecording(_ id: UUID) {
        model.selectedRecordingID = id
    }

    func requestSearchFocus() {
        model.searchFocusRequestID += 1
    }

    func startNewRecordingFromKeyboard() async {
        guard !model.isEditingText else { return }
        await startNewRecording()
    }

    func startNewRecording() async {
        guard !isPermanentlyDeleting, session.phase == .idle else { return }
        model.selectedFolder = .all
        model.searchText = ""
        model.searchBlurRequestID += 1
        model.isEditingText = false
        model.selectedRecordingID = nil
        await session.start()
    }

    func beginRename(_ id: UUID, at location: RecordingRenameSession.Location = .detail) {
        guard let recording = library.recording(id: id), recording.deletedAt == nil else { return }
        model.selectedRecordingID = id
        renameSession = RecordingRenameSession(recordingID: id, location: location)
        renameDraft = recording.title
        model.isEditingText = true
    }

    func cancelRename() {
        renameSession = nil
        renameDraft = ""
        model.isEditingText = false
    }

    func commitRename() async throws {
        guard let session = renameSession else { throw LibraryControllerError.missingSelection }
        try commitRename(sessionID: session.id)
    }

    // Focus/teardown callbacks from an old editor must not finish a newer draft.
    func cancelRename(sessionID: UUID) {
        guard renameSession?.id == sessionID else { return }
        cancelRename()
    }

    func commitRename(sessionID: UUID) throws {
        guard let session = renameSession, session.id == sessionID else { return }
        try persistRename(session.recordingID, to: renameDraft)
        cancelRename()
    }

    func rename(_ id: UUID, to title: String) async throws {
        try persistRename(id, to: title)
    }

    private func persistRename(_ id: UUID, to title: String) throws {
        try ensureIdle()
        do {
            try library.rename(id: id, to: title)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
            throw error
        }
    }

    func toggleFavorite(_ id: UUID) async throws {
        try ensureIdle()
        guard let recording = library.recording(id: id) else {
            throw LibraryStoreError.recordingNotFound(id)
        }
        do {
            try library.setFavorite(id: id, isFavorite: !recording.isFavorite)
            errorMessage = nil
            await reconcileSelectionWithVisibleRows()
        } catch {
            errorMessage = message(for: error)
            throw error
        }
    }

    func moveToRecentlyDeleted(_ id: UUID) async throws {
        try ensureIdle()
        do {
            try library.moveToRecentlyDeleted(id: id)
            errorMessage = nil
            var didStopPlayback = false
            if model.selectedRecordingID == id || playback.selectedRecordingID == id {
                await playback.stop()
                didStopPlayback = true
            }
            await reconcileSelectionAfterRemoving(id, didStopPlayback: didStopPlayback)
        } catch {
            errorMessage = message(for: error)
            throw error
        }
    }

    func restore(_ id: UUID) async throws {
        try ensureIdle()
        do {
            try library.restore(id: id)
            model.selectedFolder = .all
            model.selectedRecordingID = id
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
            throw error
        }
    }

    func requestPermanentDelete(_ id: UUID) {
        guard library.recording(id: id)?.deletedAt != nil else { return }
        pendingPermanentDeleteID = id
    }

    func cancelPermanentDelete() {
        pendingPermanentDeleteID = nil
    }

    func confirmPermanentDelete(_ confirmedID: UUID? = nil) async throws {
        guard !isPermanentlyDeleting else { return }
        guard let id = confirmedID ?? pendingPermanentDeleteID else { return }
        try ensureIdle()
        guard library.recording(id: id)?.deletedAt != nil else {
            throw LibraryStoreError.recordingNotDeleted(id)
        }
        pendingPermanentDeleteID = nil
        isPermanentlyDeleting = true
        defer { isPermanentlyDeleting = false }

        do {
            var didStopPlayback = false
            if model.selectedRecordingID == id || playback.selectedRecordingID == id {
                await playback.stop()
                didStopPlayback = true
            }
            try ensureIdle()
            guard library.recording(id: id)?.deletedAt != nil else {
                throw LibraryStoreError.recordingNotDeleted(id)
            }
            try library.deletePermanently(id: id)
            errorMessage = nil
            await reconcileSelectionAfterRemoving(id, didStopPlayback: didStopPlayback)
        } catch {
            errorMessage = message(for: error)
            throw error
        }
    }

    func exportSelectedAudio() async {
        guard let recording = selectedRecording else { return }
        do {
            try await LibraryFileActions.exportAudio(
                recording: recording,
                source: library.paths.audioURL(for: recording.id)
            )
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    func revealSelectedInFinder() {
        guard let recording = selectedRecording else { return }
        LibraryFileActions.revealInFinder(library.paths.audioURL(for: recording.id))
    }

    func shareFile(for recording: Recording) -> SharedAudioFile {
        SharedAudioFile(sourceURL: library.paths.audioURL(for: recording.id), title: recording.title)
    }

    func maintenanceMessage() -> String? {
        guard let detail = library.maintenanceError, !detail.isEmpty else { return nil }
        return "\(String(localized: "Some expired recordings could not be removed."))\n\(detail)"
    }

    func userMessage(for error: Error) -> String {
        message(for: error)
    }

    private func reconcileSelectionAfterRemoving(_ removedID: UUID, didStopPlayback: Bool = false) async {
        if model.selectedRecordingID == removedID {
            model.selectedRecordingID = visibleRecordings.first?.id
        }
        await reconcileSelectionWithVisibleRows(shouldStopPlaybackWhenEmpty: !didStopPlayback)
    }

    private func reconcileSelectionWithVisibleRows(shouldStopPlaybackWhenEmpty: Bool = true) async {
        let visibleIDs = Set(visibleRecordings.map(\.id))
        if let selectedID = model.selectedRecordingID, visibleIDs.contains(selectedID) {
            return
        }
        model.selectedRecordingID = visibleRecordings.first?.id
        if model.selectedRecordingID == nil, shouldStopPlaybackWhenEmpty {
            await playback.stop()
        }
    }

    private func ensureIdle() throws {
        guard session.phase == .idle else { throw LibraryControllerError.captureActive }
    }

    private func message(for error: Error) -> String {
        if let controllerError = error as? LibraryControllerError {
            switch controllerError {
            case .captureActive:
                return String(localized: "Library changes are unavailable while recording.")
            case .missingSelection:
                return String(localized: "Select a recording first.")
            }
        }
        if let storeError = error as? LibraryStoreError {
            switch storeError {
            case .recordingNotFound:
                return String(localized: "That recording is no longer available.")
            case .duplicateRecording:
                return String(localized: "A recording with that ID already exists.")
            case .emptyTitle:
                return String(localized: "Enter a title before saving.")
            case .recordingDeleted:
                return String(localized: "Restore this recording before changing it.")
            case .recordingNotDeleted:
                return String(localized: "Only recently deleted recordings can be permanently deleted.")
            case .metadataWriteFailed:
                return String(localized: "The change could not be saved. The original recording was preserved.")
            case .deletionFailed:
                return String(localized: "The recording could not be permanently deleted. Its files were preserved.")
            }
        }
        return error.localizedDescription
    }
}
