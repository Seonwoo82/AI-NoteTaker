import SwiftUI

struct RecordingsListView: View {
    @Bindable var controller: LibraryController
    let recordings: [Recording]
    @Binding var selectedRecordingID: UUID?
    @State private var deleteConfirmationID: UUID?

    var body: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: controller.model.searchText.isEmpty ? "tray" : "magnifyingglass"
                )
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("recordings-empty-state")
            } else {
                VStack(spacing: 0) {
                    ForEach(recordings) { recording in
                        Button {
                            controller.selectRecording(recording.id)
                        } label: {
                            RecordingRow(recording: recording, isSelected: selectedRecordingID == recording.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    selectedRecordingID == recording.id
                                        ? Color.accentColor
                                        : Color.clear,
                                    in: Rectangle()
                                )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            LibraryContextMenu(
                                recording: recording,
                                controller: controller,
                                deleteConfirmationID: $deleteConfirmationID
                            )
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            controller.beginRename(recording.id)
                        })
                        .accessibilityIdentifier("recording-row-\(recording.id.uuidString)")

                        Divider()
                            .padding(.leading, 8)
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Permanently Delete Recording?"),
            isPresented: Binding(
                get: { deleteConfirmationID != nil },
                set: { isPresented in
                    if !isPresented {
                        deleteConfirmationID = nil
                        controller.cancelPermanentDelete()
                    }
                }
            )
        ) {
            Button(String(localized: "Delete Permanently"), role: .destructive) {
                guard let id = deleteConfirmationID else { return }
                deleteConfirmationID = nil
                Task {
                    try? await controller.confirmPermanentDelete(id)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                deleteConfirmationID = nil
                controller.cancelPermanentDelete()
            }
        } message: {
            Text(String(localized: "This removes the recording file and metadata. This action cannot be undone."))
        }
    }

    private var emptyTitle: String {
        if !controller.model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No Search Results")
        }
        switch controller.model.selectedFolder {
        case .all:
            return String(localized: "No Recordings")
        case .favorites:
            return String(localized: "No Favorites")
        case .recentlyDeleted:
            return String(localized: "Recently Deleted is Empty")
        }
    }
}

private struct LibraryContextMenu: View {
    let recording: Recording
    @Bindable var controller: LibraryController
    @Binding var deleteConfirmationID: UUID?

    var body: some View {
        if recording.deletedAt == nil {
            Button(String(localized: "Rename")) {
                controller.beginRename(recording.id)
            }
            Button(recording.isFavorite ? String(localized: "Remove Favorite") : String(localized: "Favorite")) {
                Task { try? await controller.toggleFavorite(recording.id) }
            }
            ShareLink(
                item: controller.shareFile(for: recording),
                subject: Text(recording.title),
                preview: SharePreview(recording.title)
            ) {
                Text(String(localized: "Share"))
            }
            Button(String(localized: "Export...")) {
                controller.selectRecording(recording.id)
                Task { await controller.exportSelectedAudio() }
            }
            Button(String(localized: "Show in Finder")) {
                controller.selectRecording(recording.id)
                controller.revealSelectedInFinder()
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                Task { try? await controller.moveToRecentlyDeleted(recording.id) }
            }
        } else {
            Button(String(localized: "Restore")) {
                Task { try? await controller.restore(recording.id) }
            }
            Button(String(localized: "Delete Permanently"), role: .destructive) {
                controller.requestPermanentDelete(recording.id)
                deleteConfirmationID = recording.id
            }
        }
    }
}
