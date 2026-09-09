import SwiftUI

struct RecordingDetailTabsView: View {
    let recording: Recording
    let playback: PlaybackController
    let libraryController: LibraryController
    let meetingNotes: MeetingNotesService
    let aiConfiguration: AIConfiguration
    let meeting: MeetingFeatureContext
    var evidenceRequest: MeetingEvidenceRequest? = nil

    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: RecordingDetailTab = .audio
    @State private var segmentPlayback: MeetingSegmentPlayback?
    @State private var meetingMessage: String?
    @State private var handledEvidenceRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Recording Detail"), selection: $selectedTab) {
                Label(String(localized: "Audio"), systemImage: "waveform").tag(RecordingDetailTab.audio)
                Label(String(localized: "AI Meeting Notes"), systemImage: "sparkles").tag(RecordingDetailTab.notes)
                Label(String(localized: "AI Meeting"), systemImage: "person.2.wave.2").tag(RecordingDetailTab.meeting)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityIdentifier("recording-detail-tabs")

            switch selectedTab {
            case .audio:
                audioDetail
            case .notes:
                MeetingNotesView(recording: recording, service: meetingNotes, configuration: aiConfiguration,
                    resolvedTranscript: meeting.resolved(recording)?.transcript)
            case .meeting:
                meetingDetail
            }
        }
        .task(id: recording.id) {
            await meetingNotes.load(recording)
            await meeting.load(recording)
            handleEvidenceRequestIfNeeded()
        }
        .onChange(of: recording.id) { _, _ in cancelSegmentPlayback() }
        .onChange(of: evidenceRequest?.id) { _, _ in handleEvidenceRequestIfNeeded() }
        .onChange(of: selectedTab) { _, tab in
            if tab != .meeting { cancelSegmentPlayback() }
        }
        .onChange(of: meeting.analysis.status(for: recording.id)) { _, _ in meetingMessage = nil }
        .onDisappear { cancelSegmentPlayback() }
    }

    private var audioDetail: some View {
        VStack(spacing: 0) {
            PlaybackDetailView(recording: recording, controller: playback, libraryController: libraryController)
            if meetingNotes.progress(for: recording.id).isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "AI meeting notes are being prepared."))
                    Button(String(localized: "View Notes")) { selectedTab = .notes }
                }
                .font(.caption)
                .padding(.bottom, 12)
            } else if meetingNotes.document(for: recording.id) != nil {
                Button(String(localized: "View AI Meeting Notes")) { selectedTab = .notes }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 12)
            }
        }
    }

    private var meetingDetail: some View {
        MeetingConversationView(
            content: meeting.resolved(recording),
            status: segmentPlayback?.error ?? meetingMessage ?? meeting.errorMessage ?? meeting.analysis.status(for: recording.id),
            isBusy: meeting.analysis.isRunning(for: recording.id),
            hasAPIKey: aiConfiguration.hasAPIKey,
            editable: recording.deletedAt == nil,
            canPlayTurns: !meeting.enrollmentIsBusy && !meeting.recordingIsBusy(),
            profile: meeting.profile.profile,
            onAnalyze: {
                meetingMessage = nil
                meeting.errorMessage = nil
                cancelSegmentPlayback()
                meeting.analysis.analyze(recording)
            },
            onCancel: { meeting.analysis.cancel(recording.id) },
            onOpenAISettings: {
                aiConfiguration.settingsTab = "ai"
                openSettings()
            },
            onOpenProfile: {
                aiConfiguration.settingsTab = "profile"
                openSettings()
            },
            onPlayTurns: { turnIDs in playTurns(turnIDs) },
            onEdit: { kind, targetID, value in editMeeting(kind: kind, targetID: targetID, value: value) }
        )
    }

    private func editMeeting(kind: MeetingEditKind, targetID: String, value: String) {
        do {
            try meeting.edit(recording, kind: kind, targetID: targetID, value: value)
            meetingMessage = String(localized: "Meeting edit saved.")
        } catch {
            meetingMessage = error.localizedDescription
        }
    }

    private func handleEvidenceRequestIfNeeded() {
        guard let evidenceRequest, evidenceRequest.recordingID == recording.id,
              evidenceRequest.id != handledEvidenceRequestID else { return }
        handledEvidenceRequestID = evidenceRequest.id
        selectedTab = .meeting
        Task {
            await meeting.load(recording)
            playTurns(evidenceRequest.turnIDs)
            meeting.clearEvidenceRequest(evidenceRequest.id)
        }
    }

    private func playTurns(_ turnIDs: [String]) {
        guard !meeting.enrollmentIsBusy, !meeting.recordingIsBusy(), let content = meeting.resolved(recording) else { return }
        let selected = Set(turnIDs)
        let turns = content.transcript.turns.filter { selected.contains($0.id) }
        let controller = segmentPlayback ?? MeetingSegmentPlayback(
            position: { playback.exactCurrentTime },
            isPlaying: { playback.exactIsPlaying },
            playAt: { owner, time in try await playback.playSegment(recording: recording, at: time, owner: owner) },
            seek: { owner, time in await playback.seekSegment(recording: recording, owner: owner, to: time) },
            pause: { owner in await playback.stopSegment(recording: recording, owner: owner) },
            stop: { owner in await playback.stopSegment(recording: recording, owner: owner) }
        )
        segmentPlayback = controller
        Task { await controller.play(turns: turns) }
    }

    private func cancelSegmentPlayback() {
        guard let controller = segmentPlayback else { return }
        segmentPlayback = nil
        Task { await controller.stop() }
    }
}

private enum RecordingDetailTab: Hashable {
    case audio
    case notes
    case meeting
}
