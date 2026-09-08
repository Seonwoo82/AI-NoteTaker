import SwiftUI

struct RootView: View {
    @State private var model: LibraryAppModel
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init(services: AppServices) {
        _model = State(initialValue: LibraryAppModel(services: services))
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(model.visibleRecordings) { recording in
                        NavigationLink(value: recording.id) { RecordingRow(recording: recording) }
                            .contextMenu { recordingActions(recording) }
                    }
                } header: {
                    HStack {
                        Text(model.filter.title)
                        Spacer()
                        Text(model.visibleRecordings.count, format: .number)
                    }
                }
            }
            .accessibilityIdentifier("folders-sidebar")
            .overlay {
                if model.library == nil {
                    ProgressView("Opening Library…")
                } else if model.visibleRecordings.isEmpty {
                    ContentUnavailableView {
                        Label(model.search.isEmpty ? "No Recordings" : "No Results", systemImage: "waveform")
                    } description: {
                        Text(model.search.isEmpty ? "Record a thought. Find it on all your devices." : "Try a different title.")
                    }
                    .allowsHitTesting(false)
                }
            }
            .searchable(text: $model.search, prompt: "Search recordings")
            .navigationTitle("Voice Notes")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Library", selection: Binding(
                            get: { model.filter },
                            set: { model.filter = $0; model.selection = nil }
                        )) {
                            ForEach(LibraryFilter.allCases) { filter in
                                Label(filter.title, systemImage: filter.symbol).tag(filter)
                            }
                        }
                    } label: {
                        Label("Filter Recordings", systemImage: "line.3.horizontal.decrease")
                    }
                    .accessibilityIdentifier("library-filter")
                }
                ToolbarItem(placement: .automatic) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings-button")
                }
            }
            .refreshable { await model.synchronize() }
        } detail: {
            if let recording = model.selectedRecording {
                RecordingDetailTabsView(model: model, recording: recording) {
                    model.settingsSection = .ai
                    showingSettings = true
                }
                .id(recording.id)
            } else {
                ContentUnavailableView {
                    Label("No Recording Selected", systemImage: "waveform")
                } description: {
                    Text("Your ideas, ready to listen to.")
                }
                .accessibilityIdentifier("empty-detail")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RecordingBar(model: model) }
        .sheet(isPresented: $showingSettings) {
            AppSettingsView(model: model)
        }
        .task { await model.open() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.synchronize() } }
        }
        .onChange(of: model.selection) { _, _ in model.player.stop() }
        .onChange(of: model.library?.recordings) { old, new in
            model.libraryDidChange(from: old ?? [], to: new ?? [])
        }
        .alert("Unable to Complete Action", isPresented: errorPresented) {
            Button("OK") { clearErrors() }
        } message: {
            Text(model.errorMessage ?? model.recorder.errorMessage ?? model.player.errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || model.recorder.errorMessage != nil || model.player.errorMessage != nil },
            set: { if !$0 { clearErrors() } }
        )
    }

    private func clearErrors() {
        model.errorMessage = nil
        model.recorder.errorMessage = nil
        model.player.errorMessage = nil
    }

    @ViewBuilder
    private func recordingActions(_ recording: Recording) -> some View {
        if recording.deletedAt == nil {
            Button(recording.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: "star") {
                model.edit(recording) { $0.isFavorite.toggle() }
            }
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                model.edit(recording) { $0.deletedAt = .now }
            }
        } else {
            Button("Restore Recording", systemImage: "arrow.uturn.backward") {
                model.edit(recording) { $0.deletedAt = nil }
            }
        }
    }
}
