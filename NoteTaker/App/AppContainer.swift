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
    let meeting: MeetingFeatureContext
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
        let meeting = MeetingFeatureContext(library: library, configuration: aiConfiguration,
            environment: ai, notes: meetingNotes)
        let syncSettings = services.syncSettings
        let automaticallySyncs = services.automaticallySyncs
        let syncCoordinator = SyncCoordinator(settings: syncSettings)
        meetingNotes.onDocumentSaved = { [weak syncCoordinator, weak library] _ in
            guard automaticallySyncs, syncSettings.isEnabled, let syncCoordinator, let library else { return }
            Task { await syncCoordinator.sync(library: library) }
        }
        syncCoordinator.onNotesChanged = { [weak meetingNotes, weak library] id in
            guard let recording = library?.recording(id: id) else { return }
            Task { await meetingNotes?.reload(recording) }
        }
        aiConfiguration.onCredentialsChanged = { [weak meetingNotes, weak meeting] in
            meetingNotes?.credentialsDidChange()
            meeting?.credentialsDidChange()
        }
        library.onRecordingUnavailable = { [weak meetingNotes, weak meeting] id in
            meetingNotes?.cancel(id)
            meeting?.recordingUnavailable(id)
        }
        let session = RecordingSession(
            recorder: services.recorder,
            player: services.player,
            library: library,
            appModel: model,
            settings: settings,
            stopPlayback: {
                meeting.cancelEnrollment()
                meeting.refreshVoiceObservation()
                await playback.stop()
            },
            loadPreview: { url, duration in
                try await playback.loadPreview(url: url, duration: duration)
            },
            onRecordingSaved: { recording in
                meeting.recordingDidFinish(recording)
                if automaticallySyncs && syncSettings.isEnabled {
                    Task { await syncCoordinator.sync(library: library) }
                }
            }
        )
        meeting.recordingIsBusy = { [weak session] in session?.phase != .idle }
        meeting.stopPlayback = { [weak playback] in await playback?.stop() }
        meeting.attachLiveAudio = { [weak recorder = services.recorder] handler in recorder?.liveAudioHandler = handler }
        meeting.refreshVoiceObservation()
        if automaticallySyncs { Task { await meeting.restoreLocalVoiceModels() } }
        meeting.configureSync(syncCoordinator, automatic: automaticallySyncs)
        await meeting.loadLibrary()
        let libraryController = LibraryController(
            library: library,
            model: model,
            session: session,
            playback: playback,
            onLibraryChanged: {
                if automaticallySyncs && syncSettings.isEnabled {
                    Task { await syncCoordinator.sync(library: library) }
                }
            }
        )

        if automaticallySyncs {
            syncCoordinator.configureAISettingsSync(configuration: aiConfiguration, library: library)
            syncCoordinator.configureAutomaticSync(library: library)
            syncCoordinator.setAutomaticSyncActive(true)
        }

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
            meeting: meeting,
            syncSettings: syncSettings,
            syncCoordinator: syncCoordinator
        )
    }
}
