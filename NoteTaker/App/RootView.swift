import SwiftUI

@MainActor
struct RootView: View {
    let container: AppContainer?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let container {
                WorkspaceSplitView(container: container, columnVisibility: $columnVisibility)
                .onKeyPress(.space) {
                    guard !container.model.isEditingText else { return .ignored }
                    switch container.session.phase {
                    case .recording:
                        Task { await container.session.pause() }
                    case .paused:
                        Task { await container.playback.togglePlayPause() }
                    case .idle:
                        Task { await container.playback.togglePlayPause() }
                    default:
                        return .ignored
                    }
                    return .handled
                }
                .recordingAlert(session: container.session)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            Task { await container.syncCoordinator.sync(library: container.library) }
                        } label: {
                            Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(container.syncCoordinator.isSyncing)
                        .accessibilityIdentifier("sync-now-toolbar")
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let container, container.syncSettings.isEnabled else { return }
            container.syncCoordinator.requestAutomaticSync()
        }
    }
}

struct WorkspaceSplitView: View {
    let container: AppContainer
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarContent(container: container)
            .navigationSplitViewColumnWidth(min: 248, ideal: 260)
        } detail: {
            WorkspaceDetailContent(container: container)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WorkspaceContentView: View {
    let container: AppContainer

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebarContent(container: container)
                .frame(width: 260)

            Divider()

            WorkspaceDetailContent(container: container)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkspaceSidebarContent: View {
    let container: AppContainer

    var body: some View {
        SidebarView(
            controller: container.libraryController,
            model: container.model,
            settings: container.settings,
            session: container.session
        )
    }
}

private struct WorkspaceDetailContent: View {
    let container: AppContainer

    var body: some View {
        DetailView(
            library: container.library,
            model: container.model,
            session: container.session,
            settings: container.settings,
            playback: container.playback,
            libraryController: container.libraryController,
            meetingNotes: container.meetingNotes,
            aiConfiguration: container.aiConfiguration
        )
    }
}

private struct DetailView: View {
    let library: LibraryStore
    let model: AppModel
    let session: RecordingSession
    let settings: AppSettings
    let playback: PlaybackController
    let libraryController: LibraryController
    let meetingNotes: MeetingNotesService
    let aiConfiguration: AIConfiguration

    var body: some View {
        switch session.phase {
        case .preparing, .recording, .pausing, .paused, .resuming, .finishing:
            RecordingView(session: session, settings: settings, playback: playback)
        case .idle:
            if let selectedID = model.selectedRecordingID,
               let recording = library.recording(id: selectedID) {
                RecordingDetailTabsView(
                    recording: recording,
                    playback: playback,
                    libraryController: libraryController,
                    meetingNotes: meetingNotes,
                    aiConfiguration: aiConfiguration
                )
            } else {
                EmptyDetailView()
            }
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView(
            String(localized: "No Recording Selected"),
            systemImage: "waveform"
        )
        .accessibilityIdentifier("empty-detail")
    }
}

private extension View {
    func recordingAlert(session: RecordingSession) -> some View {
        modifier(RecordingAlertModifier(session: session))
    }
}

private struct RecordingAlertModifier: ViewModifier {
    @Environment(\.openURL) private var openURL

    let session: RecordingSession

    func body(content: Content) -> some View {
        content
        .alert(
            String(localized: "Recording Error"),
            isPresented: Binding(
                get: { session.alert != nil },
                set: { isPresented in
                    if !isPresented {
                        session.dismissAlert()
                    }
                }
            )
        ) {
            if let settingsURL = session.alert?.settingsURL {
                Button(String(localized: "Open Settings")) {
                    openURL(settingsURL)
                }
            }
            Button(String(localized: "Retry")) {
                Task {
                    session.dismissAlert()
                    await session.start()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                session.dismissAlert()
            }
        } message: {
            Text(session.alert?.displayMessage ?? "")
        }
    }
}
