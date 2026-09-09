import SwiftUI

struct RootView: View {
    let model: LibraryAppModel
    @State private var showingSettings = false
    @State private var showingBriefing = false
    @State private var folderEditorMode: FolderEditorMode = .create
    @State private var folderNameDraft = ""
    @State private var isFolderEditorPresented = false
    @State private var pendingFolderDeleteID: UUID?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section(String(localized: "Library")) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Button {
                            model.selectFilter(filter)
                        } label: {
                            FolderFilterRow(
                                title: filter.title,
                                symbol: filter.symbol,
                                isSelected: model.selectedCustomFolderID == nil && model.filter == filter
                            )
                        }
                        .accessibilityIdentifier("folder-\(filter.rawValue)")
                    }
                }

                Section {
                    ForEach(model.activeCustomFolders) { folder in
                        Button {
                            model.selectCustomFolder(folder.id)
                        } label: {
                            FolderFilterRow(
                                title: folder.name,
                                symbol: "folder",
                                isSelected: model.selectedCustomFolderID == folder.id
                            )
                        }
                        .contextMenu {
                            Button(String(localized: "Rename Folder"), systemImage: "pencil") {
                                presentRenameFolder(folder)
                            }
                            .disabled(model.recorder.isRecording || model.recorder.isBusy)
                            Button(String(localized: "Delete Folder"), systemImage: "trash", role: .destructive) {
                                pendingFolderDeleteID = folder.id
                            }
                            .disabled(model.recorder.isRecording || model.recorder.isBusy)
                        }
                        .accessibilityIdentifier("folder-custom-\(folder.id.uuidString)")
                    }
                } header: {
                    HStack {
                        Text(String(localized: "Folders"))
                        Spacer()
                        Button {
                            presentCreateFolder()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(model.recorder.isRecording || model.recorder.isBusy)
                        .accessibilityLabel(String(localized: "New Folder"))
                        .accessibilityIdentifier("new-folder-button")
                    }
                }

                Section {
                    if model.visibleRecordings.isEmpty, model.library != nil {
                        ContentUnavailableView {
                            Label(model.search.isEmpty ? String(localized: "No Recordings") : String(localized: "No Results"), systemImage: "waveform")
                        } description: {
                            Text(model.search.isEmpty ? String(localized: "Record a thought. Find it on all your devices.") : String(localized: "Try a different title."))
                        }
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("recordings-empty-state")
                    } else {
                        ForEach(model.visibleRecordings) { recording in
                            NavigationLink(value: recording.id) { RecordingRow(recording: recording) }
                                .contextMenu { recordingActions(recording) }
                        }
                    }
                } header: {
                    HStack {
                        Text(model.selectedFolderTitle)
                        Spacer()
                        Text(model.visibleRecordings.count, format: .number)
                    }
                }
            }
            .alert(folderEditorTitle, isPresented: $isFolderEditorPresented) {
                TextField(String(localized: "Folder Name"), text: $folderNameDraft)
                Button(folderEditorCommitTitle) {
                    commitFolderEditor()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Recordings stay in All Recordings when folders change."))
            }
            .accessibilityIdentifier("folders-sidebar")
            .overlay {
                if model.library == nil {
                    ProgressView("Opening Library…")
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
                            set: { model.selectFilter($0) }
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
                    Button { showingBriefing = true } label: {
                        Label(String(localized: "Meeting Briefing"), systemImage: "calendar.badge.clock")
                    }
                    .disabled(model.meeting?.store.documents.isEmpty ?? true)
                    .accessibilityIdentifier("meeting-briefing-toolbar")
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
        .sheet(isPresented: $showingBriefing) {
            MeetingBriefingView(sources: model.meeting?.briefingSources ?? []) { recordingID, turnIDs in
                model.meeting?.requestEvidence(recordingID: recordingID, turnIDs: turnIDs)
                model.selection = recordingID
            }
        }
        .task { await model.open() }
        .onChange(of: model.selection) { _, _ in model.player.stop() }
        .onChange(of: model.library?.recordings) { old, new in
            model.libraryDidChange(from: old ?? [], to: new ?? [])
        }
        .onChange(of: model.activeCustomFolders.map(\.id)) { _, _ in
            model.reconcileFolderSelection()
        }
        .confirmationDialog(
            String(localized: "Delete Folder?"),
            isPresented: Binding(
                get: { pendingFolderDeleteID != nil },
                set: { isPresented in if !isPresented { pendingFolderDeleteID = nil } }
            )
        ) {
            Button(String(localized: "Delete Folder"), role: .destructive) {
                guard let id = pendingFolderDeleteID else { return }
                pendingFolderDeleteID = nil
                model.deleteFolder(id: id)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingFolderDeleteID = nil
            }
        } message: {
            Text(String(localized: "Recordings in this folder stay in All Recordings and become unfiled."))
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

    private var folderEditorTitle: String {
        switch folderEditorMode {
        case .create: String(localized: "New Folder")
        case .rename: String(localized: "Rename Folder")
        }
    }

    private var folderEditorCommitTitle: String {
        switch folderEditorMode {
        case .create: String(localized: "Create")
        case .rename: String(localized: "Save")
        }
    }

    private func presentCreateFolder() {
        folderEditorMode = .create
        folderNameDraft = ""
        isFolderEditorPresented = true
    }

    private func presentRenameFolder(_ folder: RecordingCollectionFolder) {
        folderEditorMode = .rename(folder.id)
        folderNameDraft = folder.name
        isFolderEditorPresented = true
    }

    private func commitFolderEditor() {
        switch folderEditorMode {
        case .create:
            _ = model.createFolder(named: folderNameDraft)
        case let .rename(id):
            model.renameFolder(id: id, to: folderNameDraft)
        }
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
            Menu(String(localized: "Move to Folder"), systemImage: "folder") {
                Button(String(localized: "No Folder")) {
                    model.moveRecording(recording, toFolder: nil)
                }
                ForEach(model.activeCustomFolders) { folder in
                    Button(folder.name) {
                        model.moveRecording(recording, toFolder: folder.id)
                    }
                }
            }
        } else {
            Button("Restore Recording", systemImage: "arrow.uturn.backward") {
                model.edit(recording) { $0.deletedAt = nil }
            }
        }
    }
}

private enum FolderEditorMode: Equatable {
    case create
    case rename(UUID)
}

private struct FolderFilterRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
        }
    }
}
