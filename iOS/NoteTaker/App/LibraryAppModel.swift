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
    @ObservationIgnored private let aiEnvironment: AIEnvironment
    @ObservationIgnored private let isTesting: Bool
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private let backgroundExecution = SyncBackgroundExecution()
    private var isForeground = false
    var settingsSection: AppSettingsSection = .ai
    var selection: UUID?
    var filter: LibraryFilter = .all
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
        return filter.recordings(in: library, search: search)
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
        aiConfiguration.onCredentialsChanged = { [weak notes] in notes?.credentialsDidChange() }
        notes.onDocumentSaved = { [weak self] _ in
            Task { await self?.synchronize() }
        }
        sync.onNotesChanged = { [weak notes, weak openedLibrary] id in
            guard let recording = openedLibrary?.recording(id: id) else { return }
            Task { await notes?.reload(recording) }
        }
        meetingNotes = notes
        library = openedLibrary
        _ = await recorder.recoverRecordings(library: openedLibrary)
        if !isTesting {
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
        player.stop()
        await recorder.start(library: library, mode: captureMode)
    }

    func finishRecording() async {
        guard let library else { return }
        if let recording = await recorder.finish(library: library) {
            filter = .all
            search = ""
            selection = recording.id
            meetingNotes?.recordingDidFinish(recording)
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
        catch { errorMessage = error.localizedDescription }
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
            }
        }
        Task { await synchronize() }
    }
}

enum AppSettingsSection: String, CaseIterable, Identifiable {
    case ai, sync
    var id: Self { self }
    var title: String {
        switch self {
        case .ai: String(localized: "AI Meeting Notes")
        case .sync: String(localized: "Sync")
        }
    }
}
