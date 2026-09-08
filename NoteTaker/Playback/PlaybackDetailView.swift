import SwiftUI

struct PlaybackDetailView: View {
    let recording: Recording
    @Bindable var controller: PlaybackController
    @Bindable var libraryController: LibraryController
    @State private var confirmPermanentDelete = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 3) {
                titleView
                Text(DateFormat.recordingList.string(from: recording.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(recording.mode.localizedLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(spacing: 6) {
                WaveformView(
                    peaks: controller.waveformPeaks,
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    prominence: .primary,
                    onSeek: { newValue in
                        Task { await controller.seek(to: newValue) }
                    }
                )
                .frame(height: 148)
                .overlay {
                    if controller.waveformPeaks.isEmpty {
                        if controller.isLoadingWaveform {
                            ProgressView(String(localized: "Loading waveform..."))
                                .controlSize(.small)
                        } else {
                            VStack(spacing: 8) {
                                Text(String(localized: "Waveform unavailable"))
                                    .foregroundStyle(.secondary)
                                Button(String(localized: "Reload Waveform")) {
                                    Task { try? await prepareSelectedRecording() }
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }
                    }
                }
                .accessibilityIdentifier("waveform-view")

                WaveformView(
                    peaks: controller.waveformPeaks,
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    prominence: .overview,
                    onSeek: { newValue in
                        Task { await controller.seek(to: newValue) }
                    }
                )
                .frame(height: 30)
                .accessibilityIdentifier("overview-waveform")

                HStack {
                    Text(DurationFormat.list(controller.currentTime))
                    Spacer()
                    Text(DurationFormat.list(controller.duration))
                }
                .font(.system(.caption, design: .monospaced))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timeAccessibilityLabel)
                .accessibilityIdentifier("playback-time-label")
            }
            .frame(maxWidth: 560)

            Spacer(minLength: 0)

            TransportControls(controller: controller)
                .padding(.top, -18)

            actionBar

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityIdentifier("playback-error")
            }
            if let errorMessage = libraryController.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityIdentifier("library-error")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("playback-detail")
        .task(id: PlaybackRecordingIdentity(recording)) {
            try? await prepareSelectedRecording()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { try? await prepareSelectedRecording() }
            }
        }
        .onChange(of: controller.isReadyForDisplay(recording: recording)) { _, ready in
            if !ready {
                Task { try? await prepareSelectedRecording() }
            }
        }
        .confirmationDialog(
            String(localized: "Permanently Delete Recording?"),
            isPresented: $confirmPermanentDelete
        ) {
            Button(String(localized: "Delete Permanently"), role: .destructive) {
                Task { try? await libraryController.confirmPermanentDelete(recording.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This removes the recording file and metadata. This action cannot be undone."))
        }
    }

    private var timeAccessibilityLabel: String {
        "\(DurationFormat.list(controller.currentTime)) / \(DurationFormat.list(controller.duration))"
    }

    private func prepareSelectedRecording() async throws {
        guard !Task.isCancelled,
              let current = libraryController.selectedRecording,
              current.id == recording.id else { return }
        // A focus callback can outlive the view that scheduled it. Resolve the
        // still-selected row again instead of reopening a stale recording.
        try await controller.prepareForDisplay(recording: current)
    }

    @ViewBuilder
    private var titleView: some View {
        if let session = libraryController.renameSession,
           session.recordingID == recording.id, session.location == .detail {
            RecordingTitleEditor(controller: libraryController, session: session)
                .frame(maxWidth: 360)
                .id(session.id)
        } else {
            Text(recording.title)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .onTapGesture(count: 2) {
                    libraryController.beginRename(recording.id)
                }
                .accessibilityIdentifier("recording-title-label")
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            if recording.deletedAt == nil {
                Button(String(localized: "Rename")) {
                    libraryController.beginRename(recording.id)
                }
                Button(recording.isFavorite ? String(localized: "Remove Favorite") : String(localized: "Favorite")) {
                    Task { try? await libraryController.toggleFavorite(recording.id) }
                }
                ShareLink(
                    item: libraryController.shareFile(for: recording),
                    subject: Text(recording.title),
                    preview: SharePreview(recording.title)
                ) {
                    Text(String(localized: "Share"))
                }
                Button(String(localized: "Export...")) {
                    Task { await libraryController.exportSelectedAudio() }
                }
                Button(String(localized: "Show in Finder")) {
                    libraryController.revealSelectedInFinder()
                }
                Button(String(localized: "Delete"), role: .destructive) {
                    Task { try? await libraryController.moveToRecentlyDeleted(recording.id) }
                }
            } else {
                Button(String(localized: "Restore")) {
                    Task { try? await libraryController.restore(recording.id) }
                }
                Button(String(localized: "Delete Permanently"), role: .destructive) {
                    confirmPermanentDelete = true
                }
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
        .disabled(libraryController.model.isEditingText && libraryController.renamingRecordingID != recording.id)
        .accessibilityIdentifier("detail-action-bar")
    }
}
