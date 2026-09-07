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

    static func load(services: AppServices, paths: LibraryPaths = LibraryPaths()) async -> AppContainer {
        let library = await LibraryStore.open(paths: paths)
        let model = AppModel()
        model.selectedRecordingID = library.filteredRecordings(in: .all).first?.id
        let settings = AppSettings(audioDeviceProvider: services.audioDeviceProvider)
        let playback = PlaybackController(player: services.player, library: library)
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
            }
        )
        let libraryController = LibraryController(
            library: library,
            model: model,
            session: session,
            playback: playback
        )

        return AppContainer(
            services: services,
            library: library,
            model: model,
            settings: settings,
            session: session,
            playback: playback,
            libraryController: libraryController
        )
    }
}
