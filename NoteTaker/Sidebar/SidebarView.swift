import SwiftUI

struct SidebarView: View {
    @Bindable var controller: LibraryController
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    let session: RecordingSession
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selectedFolder.localizedTitle)
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
                                isSelected: model.selectedFolder == folder
                            ) {
                                Task { await controller.selectFolder(folder) }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedFolder.localizedTitle)
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
        .navigationTitle("NoteTaker")
        .accessibilityIdentifier("folders-sidebar")
        .onChange(of: isSearchFocused) { _, isFocused in
            model.isEditingText = isFocused || controller.renameSession != nil
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
    }
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
