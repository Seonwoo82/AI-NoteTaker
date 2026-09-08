import Foundation

@MainActor
struct AppContainer {
    let services: AppServices
    let library: LibraryStore
    let model: AppModel
    let settings: AppSettings
    let session: RecordingSession
    let playback: PlaybackController
    let libraryController: LibraryController
    let aiConfiguration: AIConfiguration
    let meetingNotes: MeetingNotesService
    let syncSettings: SyncSettings
    let syncCoordinator: SyncCoordinator

    static func load(services: AppServices, paths: LibraryPaths = LibraryPaths()) async -> AppContainer {
        let library = await LibraryStore.open(paths: paths)
        let model = AppModel()
        model.selectedRecordingID = library.filteredRecordings(in: .all).first?.id
        let settings = AppSettings(audioDeviceProvider: services.audioDeviceProvider)
        let playback = PlaybackController(player: services.player, library: library)
        let ai = services.aiEnvironment ?? .testing()
        let aiConfiguration = AIConfiguration(client: ai.client, keyStore: ai.keyStore, defaults: ai.defaults)
        let meetingNotes = MeetingNotesService(configuration: aiConfiguration, client: ai.client,
                                              chunker: ai.chunker, library: library)
        let syncSettings = services.syncSettings
        let syncCoordinator = SyncCoordinator(settings: syncSettings)
        meetingNotes.onDocumentSaved = { [weak syncCoordinator, weak library] _ in
            guard syncSettings.isEnabled, let syncCoordinator, let library else { return }
            Task { await syncCoordinator.sync(library: library) }
        }
        syncCoordinator.onNotesChanged = { [weak meetingNotes, weak library] id in
            guard let recording = library?.recording(id: id) else { return }
            Task { await meetingNotes?.reload(recording) }
        }
        aiConfiguration.onCredentialsChanged = { [weak meetingNotes] in meetingNotes?.credentialsDidChange() }
        library.onRecordingUnavailable = { [weak meetingNotes] id in meetingNotes?.cancel(id) }
        let session = RecordingSession(
            recorder: services.recorder,
            player: services.player,
            library: library,
            appModel: model,
            settings: settings,
            stopPlayback: {
                await playback.stop()
            },
            loadPreview: { url, duration in
                try await playback.loadPreview(url: url, duration: duration)
            },
            onRecordingSaved: { recording in
                meetingNotes.recordingDidFinish(recording)
                if syncSettings.isEnabled {
                    Task { await syncCoordinator.sync(library: library) }
                }
            }
        )
        let libraryController = LibraryController(
            library: library,
            model: model,
            session: session,
            playback: playback,
            onLibraryChanged: {
                if syncSettings.isEnabled {
                    Task { await syncCoordinator.sync(library: library) }
                }
            }
        )

        return AppContainer(
            services: services,
            library: library,
            model: model,
            settings: settings,
            session: session,
            playback: playback,
            libraryController: libraryController,
            aiConfiguration: aiConfiguration,
            meetingNotes: meetingNotes,
            syncSettings: syncSettings,
            syncCoordinator: syncCoordinator
        )
    }
}
