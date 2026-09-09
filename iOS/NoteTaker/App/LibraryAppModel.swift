import Foundation
import Observation
#if canImport(AudioPipeline)
import AudioPipeline
#endif

@MainActor
@Observable
final class LibraryAppModel {
    private(set) var library: LibraryStore?
    let recorder: VoiceRecorder
    let player: VoicePlayer
    let settings: SyncSettings
    let sync: SyncCoordinator
    let aiConfiguration: AIConfiguration
    private(set) var meetingNotes: MeetingNotesService?
    private(set) var meeting: MeetingFeatureContext?
    @ObservationIgnored private let aiEnvironment: AIEnvironment
    @ObservationIgnored private let isTesting: Bool
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private let backgroundExecution = SyncBackgroundExecution()
    private var isForeground = false
    var settingsSection: AppSettingsSection = .ai
    var selection: UUID?
    var filter: LibraryFilter = .all
    var selectedCustomFolderID: UUID?
    private var captureFolderID: UUID?
    var search = ""
    var captureMode: CaptureMode = .micOnly
    var errorMessage: String?

    init(services: AppServices, aiEnvironment: AIEnvironment? = nil, syncSettings: SyncSettings? = nil) {
        recorder = services.recorder
        player = services.player
        isTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting") ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if let syncSettings {
            settings = syncSettings
        } else if isTesting {
            let namespace = "com.seonwoo.notetaker.uitesting.\(UUID().uuidString)"
            settings = SyncSettings(
                defaults: UserDefaults(suiteName: namespace) ?? .standard,
                tokenStore: SystemKeychainTokenStore(service: namespace)
            )
        } else {
            settings = SyncSettings()
        }
        sync = SyncCoordinator(settings: settings)
        let environment = aiEnvironment ?? (isTesting ? .testing() : .live())
        self.aiEnvironment = environment
        aiConfiguration = AIConfiguration(client: environment.client, keyStore: environment.keyStore, defaults: environment.defaults)
    }

    var visibleRecordings: [Recording] {
        guard let library else { return [] }
        if let selectedCustomFolderID {
            return recordings(inCustomFolder: selectedCustomFolderID, library: library, search: search)
        }
        return filter.recordings(in: library, search: search)
    }

    var activeCustomFolders: [RecordingCollectionFolder] {
        library?.folderStore.activeFolders ?? []
    }

    var selectedFolderTitle: String {
        guard let library,
              let selectedCustomFolderID,
              library.folderStore.isActive(id: selectedCustomFolderID),
              let folder = library.folderStore.folder(id: selectedCustomFolderID) else {
            return filter.title
        }
        return folder.name
    }

    var selectedRecording: Recording? {
        guard let selection else { return nil }
        return library?.recording(id: selection)
    }

    func open(paths suppliedPaths: LibraryPaths? = nil) async {
        if let openingTask { await openingTask.value; return }
        guard library == nil else { return }
        let task = Task { await self.openLibrary(paths: suppliedPaths) }
        openingTask = task
        await task.value
        openingTask = nil
    }

    private func openLibrary(paths suppliedPaths: LibraryPaths?) async {
        let arguments = ProcessInfo.processInfo.arguments
        let paths: LibraryPaths
        if let suppliedPaths {
            paths = suppliedPaths
        } else if isTesting, !arguments.contains("-libraryRoot") {
            paths = LibraryPaths(libraryRoot: FileManager.default.temporaryDirectory
                .appending(path: "NoteTakerUITest-\(UUID().uuidString)"))
        } else {
            paths = LibraryPaths()
        }
        let openedLibrary = await LibraryStore.open(paths: paths)
        let notes = MeetingNotesService(configuration: aiConfiguration, client: aiEnvironment.client,
                                        chunker: aiEnvironment.chunker, library: openedLibrary)
        let meeting = MeetingFeatureContext(library: openedLibrary, configuration: aiConfiguration,
            environment: aiEnvironment, notes: notes)
        self.meeting = meeting
        meeting.recordingIsBusy = { [weak self] in
            guard let self else { return true }
            return self.recorder.isRecording || self.recorder.isBusy
        }
        meeting.stopPlayback = { [weak self] in self?.player.stop() }
        meeting.attachLiveAudio = { [weak self] handler in self?.recorder.liveAudioHandler = handler }
        meeting.refreshVoiceObservation()
        if !isTesting { Task { await meeting.restoreLocalVoiceModels() } }
        meeting.configureSync(sync, automatic: !isTesting)
        aiConfiguration.onCredentialsChanged = { [weak notes, weak meeting] in
            notes?.credentialsDidChange()
            meeting?.credentialsDidChange()
        }
        notes.onDocumentSaved = { [weak self] _ in
            guard let self, !self.isTesting else { return }
            Task { await self.synchronize() }
        }
        sync.onNotesChanged = { [weak notes, weak openedLibrary] id in
            guard let recording = openedLibrary?.recording(id: id) else { return }
            Task { await notes?.reload(recording) }
        }
        openedLibrary.onRecordingUnavailable = { [weak notes, weak meeting] id in
            notes?.cancel(id)
            meeting?.recordingUnavailable(id)
        }
        meetingNotes = notes
        library = openedLibrary
        await meeting.loadLibrary()
        _ = await recorder.recoverRecordings(library: openedLibrary)
        if !isTesting {
            sync.configureAISettingsSync(configuration: aiConfiguration, library: openedLibrary)
            sync.configureAutomaticSync(library: openedLibrary, canSync: { [weak self] in
                guard let self else { return false }
                return !self.recorder.isRecording && !self.recorder.isBusy
            })
            sync.onSettingsChanged = { [weak self] in
                guard let self else { return }
                IOSBackgroundSync.schedule(enabled: self.settings.isEnabled)
            }
            sync.setAutomaticSyncActive(isForeground)
        }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        guard !isTesting else { return }
        sync.setAutomaticSyncActive(foreground)
        if foreground {
            sync.requestAutomaticSync()
        } else {
            meeting?.cancelEnrollment()
            // iOS may suspend foreground AI work; resume explicitly from the detail page.
            if !recorder.isRecording { meeting?.credentialsDidChange() }
            IOSBackgroundSync.schedule(enabled: settings.isEnabled)
            guard settings.isEnabled else { return }
            backgroundExecution.begin(operation: { [weak self] in
                await self?.synchronize()
            }, onExpiration: { [weak self] in
                guard let self, !self.isForeground else { return }
                self.sync.cancelCurrentSync()
            })
        }
    }

    func refreshInBackground() async {
        guard !isTesting else { return }
        IOSBackgroundSync.schedule(enabled: settings.isEnabled)
        await withTaskCancellationHandler {
            await open()
            guard !Task.isCancelled else { return }
            await synchronize()
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, !self.isForeground else { return }
                self.sync.cancelCurrentSync()
            }
        }
    }

    func startRecording() async {
        guard let library else { return }
        meeting?.cancelEnrollment()
        meeting?.refreshVoiceObservation()
        player.stop()
        captureFolderID = selectedCustomFolderID
        await recorder.start(library: library, mode: captureMode)
        if !recorder.isRecording { captureFolderID = nil }
    }

    func finishRecording() async {
        guard let library else { return }
        let folderID = captureFolderID
        defer { captureFolderID = nil }
        if let recording = await recorder.finish(library: library) {
            if let folderID, library.folderStore.isActive(id: folderID) {
                do {
                    try library.moveRecording(id: recording.id, toFolder: folderID)
                    selectedCustomFolderID = folderID
                } catch {
                    errorMessage = userMessage(for: error)
                }
            } else {
                filter = .all
                selectedCustomFolderID = nil
            }
            search = ""
            selection = recording.id
            meeting?.recordingDidFinish(recording)
            await synchronize()
        }
    }

    func edit(_ recording: Recording, change: (inout Recording) -> Void) {
        guard let library, var current = library.recording(id: recording.id) else { return }
        change(&current)
        do {
            try library.update(current)
            if current.deletedAt != nil {
                meetingNotes?.cancel(current.id)
                meeting?.recordingUnavailable(current.id)
                if player.recordingID == current.id { player.stop() }
            }
            Task { await synchronize() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(_ recording: Recording) {
        guard let library else { return }
        do { try player.play(recording: recording, url: library.audioURL(for: recording)) }
        catch { errorMessage = userMessage(for: error) }
    }

    func selectFilter(_ newFilter: LibraryFilter) {
        filter = newFilter
        selectedCustomFolderID = nil
        reconcileSelectionWithVisibleRecordings()
    }

    func selectCustomFolder(_ id: UUID) {
        guard library?.folderStore.isActive(id: id) == true else {
            filter = .all
            selectedCustomFolderID = nil
            reconcileSelectionWithVisibleRecordings()
            return
        }
        selectedCustomFolderID = id
        reconcileSelectionWithVisibleRecordings()
    }

    @discardableResult
    func createFolder(named name: String) -> RecordingCollectionFolder? {
        guard canChangeLibrary(), let library else { return nil }
        do {
            let folder = try library.folderStore.create(name: name)
            selectedCustomFolderID = folder.id
            errorMessage = nil
            Task { await synchronize() }
            return folder
        } catch {
            errorMessage = userMessage(for: error)
            return nil
        }
    }

    func renameFolder(id: UUID, to name: String) {
        guard canChangeLibrary(), let library else { return }
        do {
            try library.folderStore.rename(id: id, name: name)
            errorMessage = nil
            Task { await synchronize() }
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func deleteFolder(id: UUID) {
        guard canChangeLibrary(), let library else { return }
        do {
            try library.folderStore.delete(id: id)
            errorMessage = nil
            if selectedCustomFolderID == id {
                filter = .all
                selectedCustomFolderID = nil
                reconcileSelectionWithVisibleRecordings()
            }
            Task { await synchronize() }
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func moveRecording(_ recording: Recording, toFolder folderID: UUID?) {
        guard canChangeLibrary(), let library else { return }
        do {
            try library.moveRecording(id: recording.id, toFolder: folderID)
            errorMessage = nil
            reconcileSelectionWithVisibleRecordings()
            Task { await synchronize() }
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func reconcileFolderSelection() {
        guard let selectedCustomFolderID,
              library?.folderStore.isActive(id: selectedCustomFolderID) != true else { return }
        filter = .all
        self.selectedCustomFolderID = nil
        reconcileSelectionWithVisibleRecordings()
    }

    func synchronize() async {
        guard let library, settings.isEnabled, !recorder.isRecording, !recorder.isBusy else { return }
        await sync.sync(library: library)
    }

    func libraryDidChange(from oldRecordings: [Recording], to newRecordings: [Recording]) {
        for previous in oldRecordings {
            let current = newRecordings.first { $0.id == previous.id }
            if current == nil || current?.deletedAt != nil || current?.audioVersion != previous.audioVersion {
                meetingNotes?.cancel(previous.id)
                meeting?.recordingUnavailable(previous.id)
            }
        }
        reconcileFolderSelection()
        Task { await synchronize() }
    }

    private func canChangeLibrary() -> Bool {
        guard !recorder.isRecording, !recorder.isBusy else {
            errorMessage = String(localized: "Library changes are unavailable while recording.")
            return false
        }
        return true
    }

    private func reconcileSelectionWithVisibleRecordings() {
        let visibleIDs = Set(visibleRecordings.map(\.id))
        if let selection, visibleIDs.contains(selection) { return }
        selection = visibleRecordings.first?.id
        if selection == nil { player.stop() }
    }

    private func recordings(inCustomFolder folderID: UUID, library: LibraryStore, search: String) -> [Recording] {
        guard library.folderStore.isActive(id: folderID) else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.recordings.filter { recording in
            guard recording.deletedAt == nil, recording.folderID == folderID else { return false }
            return query.isEmpty || recording.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func userMessage(for error: Error) -> String {
        if let libraryError = error as? LibraryStoreError {
            switch libraryError {
            case .folderNotFound: return String(localized: "That folder is no longer available.")
            case .recordingNotFound: return String(localized: "That recording is no longer available.")
            }
        }
        if let folderError = error as? RecordingFolderStoreError {
            switch folderError {
            case .folderNotFound:
                return String(localized: "That folder is no longer available.")
            case .folderDeleted:
                return String(localized: "That folder has been deleted.")
            case .duplicateName:
                return String(localized: "A folder with that name already exists.")
            case .emptyName:
                return String(localized: "Enter a folder name before saving.")
            case .nameTooLong:
                return String(localized: "Folder names must be shorter.")
            case .tooManyFolders:
                return String(localized: "Delete a folder before creating another one.")
            case .invalidMetadata:
                return String(localized: "The folder data could not be read.")
            case .metadataWriteFailed:
                return String(localized: "The folder change could not be saved.")
            }
        }
        return error.localizedDescription
    }
}

enum AppSettingsSection: String, CaseIterable, Identifiable {
    case ai, profile, sync
    var id: Self { self }
    var title: String {
        switch self {
        case .ai: String(localized: "AI Meeting Notes")
        case .sync: String(localized: "Sync")
        case .profile: String(localized: "Profile")
        }
    }
}
