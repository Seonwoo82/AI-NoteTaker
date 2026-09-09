import SwiftUI

struct SidebarView: View {
    @Bindable var controller: LibraryController
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    let session: RecordingSession
    @FocusState private var isSearchFocused: Bool
    @State private var folderEditorMode: FolderEditorMode = .create
    @State private var folderNameDraft = ""
    @State private var isFolderEditorPresented = false
    @State private var pendingFolderDeleteID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.selectedFolderTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .fontWeight(.semibold)
                TextField(String(localized: "Search"), text: Binding(
                    get: { model.searchText },
                    set: { controller.setSearchText($0) }
                ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("sidebar-search-field")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(RecordingFolder.allCases) { folder in
                            SidebarFolderButton(
                                folder: folder,
                                count: controller.count(for: folder),
                                isSelected: model.selectedCustomFolderID == nil && model.selectedFolder == folder
                            ) {
                                Task { await controller.selectFolder(folder) }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(String(localized: "Folders"))
                                .font(.system(size: 10, weight: .semibold))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            Button {
                                presentCreateFolder()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .disabled(session.phase != .idle)
                            .help(String(localized: "New Folder"))
                            .accessibilityLabel(String(localized: "New Folder"))
                            .accessibilityIdentifier("new-folder-button")
                        }
                        .padding(.horizontal, 8)

                        ForEach(controller.activeCustomFolders) { folder in
                            CustomFolderButton(
                                folder: folder,
                                count: controller.count(forCustomFolder: folder.id),
                                isSelected: model.selectedCustomFolderID == folder.id,
                                isDisabled: session.phase != .idle
                            ) {
                                Task { await controller.selectCustomFolder(folder.id) }
                            }
                            .contextMenu {
                                Button(String(localized: "Rename Folder")) {
                                    presentRenameFolder(folder)
                                }
                                .disabled(session.phase != .idle)
                                Button(String(localized: "Delete Folder"), role: .destructive) {
                                    pendingFolderDeleteID = folder.id
                                }
                                .disabled(session.phase != .idle)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.selectedFolderTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)

                        RecordingsListView(
                            controller: controller,
                            recordings: controller.visibleRecordings,
                            selectedRecordingID: $model.selectedRecordingID
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .safeAreaInset(edge: .bottom) {
            RecordButton(session: session, settings: settings) {
                Task { await controller.startNewRecording() }
            }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .navigationTitle("AI-NoteTaker")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders-sidebar")
        .onChange(of: isSearchFocused) { _, isFocused in
            model.isEditingText = isFocused || isFolderEditorPresented || controller.renameSession != nil
        }
        .onChange(of: model.searchFocusRequestID) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: model.searchBlurRequestID) { _, _ in
            isSearchFocused = false
        }
        .onDisappear {
            if controller.renameSession == nil {
                model.isEditingText = false
            }
        }
        .task { await controller.reconcileFolderSelection() }
        .onChange(of: controller.activeCustomFolders.map(\.id)) { _, _ in
            Task { await controller.reconcileFolderSelection() }
        }
        .onChange(of: isFolderEditorPresented) { _, presented in
            model.isEditingText = presented || isSearchFocused || controller.renameSession != nil
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
                Task { try? await controller.deleteFolder(id: id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingFolderDeleteID = nil
            }
        } message: {
            Text(String(localized: "Recordings in this folder stay in All Recordings and become unfiled."))
        }
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
            _ = try? controller.createFolder(named: folderNameDraft)
        case let .rename(id):
            try? controller.renameFolder(id: id, to: folderNameDraft)
        }
    }
}

private enum FolderEditorMode: Equatable {
    case create
    case rename(UUID)
}

private struct SidebarFolderButton: View {
    let folder: RecordingFolder
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(folder.localizedTitle, systemImage: folder.systemImage)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("folder-\(folder.rawValue)")
    }
}

private struct CustomFolderButton: View {
    let folder: RecordingCollectionFolder
    let count: Int
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(folder.name, systemImage: "folder")
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("folder-custom-\(folder.id.uuidString)")
    }
}
