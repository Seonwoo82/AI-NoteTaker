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

            // Navigation stays reachable even with many expanded folders or a long recording list.
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
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        folderTree

                        if model.selectedCustomFolderID == nil {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(controller.selectedFolderTitle)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                RecordingsListView(
                                    controller: controller,
                                    recordings: controller.visibleRecordings,
                                    selectedRecordingID: $model.selectedRecordingID
                                )
                            }
                            .id("recording-list")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.sidebarScrollRequestID) { _, _ in
                    proxy.scrollTo(model.sidebarScrollTarget, anchor: .top)
                }
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
        .dragContainer(for: SidebarDragItem.self, itemID: \.self) { (items: [SidebarDragItem]) in items }
        .dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowCopy: false, allowMove: true),
                                             operationsOutsideApp: .init(allowCopy: false)))
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

    private var folderTree: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(localized: "Folders"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { presentCreateFolder() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!controller.canOrganizeLibrary)
                .help(String(localized: "New Folder"))
                .accessibilityLabel(String(localized: "New Folder"))
                .accessibilityIdentifier("new-folder-button")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 3)

            ForEach(controller.activeCustomFolders) { folder in
                VStack(spacing: 0) {
                    CustomFolderRow(
                        folder: folder,
                        count: controller.count(forCustomFolder: folder.id),
                        isSelected: model.selectedCustomFolderID == folder.id,
                        isExpanded: model.expandedCustomFolderIDs.contains(folder.id),
                        controller: controller,
                        toggle: { Task { await controller.toggleCustomFolder(folder.id) } },
                        select: { Task { await controller.selectCustomFolder(folder.id) } }
                    )
                    .contextMenu {
                        Button(String(localized: "Rename Folder")) { presentRenameFolder(folder) }
                            .disabled(!controller.canOrganizeLibrary)
                        Button(String(localized: "Delete Folder"), role: .destructive) {
                            pendingFolderDeleteID = folder.id
                        }
                        .disabled(!controller.canOrganizeLibrary)
                    }

                    if model.expandedCustomFolderIDs.contains(folder.id) {
                        RecordingsListView(
                            controller: controller,
                            recordings: controller.recordings(inCustomFolder: folder.id),
                            selectedRecordingID: $model.selectedRecordingID,
                            folderID: folder.id
                        )
                        .padding(.leading, 20)
                        .modifier(SidebarDropTargetModifier(controller: controller, target: .folder(folder.id), allowsFolderReorder: false))
                    }
                }
                .id(folder.id.uuidString)
            }

            if !controller.activeCustomFolders.isEmpty {
                Label(String(localized: "Drop to Remove from Folder"), systemImage: "tray.and.arrow.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                    .modifier(SidebarDropTargetModifier(controller: controller, target: .unfiled))
                    .accessibilityIdentifier("unfiled-drop-target")
            }
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

private struct CustomFolderRow: View {
    let folder: RecordingCollectionFolder
    let count: Int
    let isSelected: Bool
    let isExpanded: Bool
    let controller: LibraryController
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? String(localized: "Collapse Folder") : String(localized: "Expand Folder"))
            .accessibilityValue(folder.name)
            .accessibilityIdentifier("folder-disclosure-\(folder.id.uuidString)")

            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("folder-custom-\(folder.id.uuidString)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .draggable(SidebarDragItem.self, id: \.self, item: controller.canOrganizeLibrary ? .folder(folder.id) : nil)
        .modifier(SidebarDropTargetModifier(controller: controller, target: .folder(folder.id)))
        .help(String(localized: "Drop recordings inside; drag folders above or below to reorder."))
    }
}
