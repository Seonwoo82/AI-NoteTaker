import SwiftUI

struct RecordingDetailTabsView: View {
    let model: LibraryAppModel
    let recording: Recording
    let openAISettings: () -> Void

    @State private var selectedTab: RecordingDetailTab = .audio
    @State private var segmentPlayback: MeetingSegmentPlayback?
    @State private var meetingMessage: String?
    @State private var handledEvidenceRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Recording Detail"), selection: $selectedTab) {
                Label(String(localized: "Audio"), systemImage: "waveform").tag(RecordingDetailTab.audio)
                Label(String(localized: "AI Meeting Notes"), systemImage: "sparkles").tag(RecordingDetailTab.notes)
                if model.meeting != nil {
                    Label(String(localized: "AI Meeting"), systemImage: "person.2.wave.2").tag(RecordingDetailTab.meeting)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("recording-detail-tabs")

            switch selectedTab {
            case .audio:
                audioDetail
            case .notes:
                if let notes = model.meetingNotes {
                    MeetingNotesView(recording: recording, service: notes,
                                     configuration: model.aiConfiguration,
                                     openAISettings: openAISettings,
                                     resolvedTranscript: model.meeting?.resolved(recording)?.transcript,
                                     participantPreparationProgress: model.meeting?.analysis.participantPreparationProgress(for: recording.id))
                } else {
                    RecordingDetailView(model: model, recording: recording)
                }
            case .meeting:
                if let meeting = model.meeting {
                    meetingDetail(meeting)
                } else {
                    RecordingDetailView(model: model, recording: recording)
                }
            }
        }
        .navigationTitle(String(localized: "Recording"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: recording.id) {
            await model.meetingNotes?.load(recording)
            await model.meeting?.load(recording)
            handleEvidenceRequestIfNeeded()
        }
        .onChange(of: recording.id) { _, _ in cancelSegmentPlayback() }
        .onChange(of: model.meeting?.evidenceRequest?.id) { _, _ in handleEvidenceRequestIfNeeded() }
        .onChange(of: selectedTab) { _, tab in
            if tab != .meeting { cancelSegmentPlayback() }
        }
        .onChange(of: model.meeting?.analysis.status(for: recording.id)) { _, _ in meetingMessage = nil }
        .onDisappear { cancelSegmentPlayback() }
    }

    private var audioDetail: some View {
        VStack(spacing: 0) {
            RecordingDetailView(model: model, recording: recording)
            if let notes = model.meetingNotes {
                if notes.progress(for: recording.id).isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "AI meeting notes are being prepared."))
                        Button(String(localized: "View Notes")) { selectedTab = .notes }
                    }
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                } else if notes.document(for: recording.id) != nil {
                    Button(String(localized: "View AI Meeting Notes")) { selectedTab = .notes }
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func meetingDetail(_ meeting: MeetingFeatureContext) -> some View {
        MeetingConversationView(
            content: meeting.resolved(recording),
            status: segmentPlayback?.error ?? meetingMessage ?? meeting.errorMessage ?? meeting.analysis.status(for: recording.id),
            isBusy: meeting.analysis.isRunning(for: recording.id),
            hasAPIKey: model.aiConfiguration.hasAPIKey,
            editable: recording.deletedAt == nil,
            canPlayTurns: !meeting.enrollmentIsBusy && !model.recorder.isRecording && !model.recorder.isBusy,
            profile: meeting.profile.profile,
            onAnalyze: {
                meetingMessage = nil
                meeting.errorMessage = nil
                cancelSegmentPlayback()
                meeting.analysis.analyze(recording)
            },
            onCancel: { meeting.analysis.cancel(recording.id) },
            onOpenAISettings: openAISettings,
            onOpenProfile: {
                model.settingsSection = .profile
                openAISettings()
            },
            onPlayTurns: { turnIDs in playTurns(turnIDs, meeting: meeting) },
            onEdit: { kind, targetID, value in editMeeting(meeting, kind: kind, targetID: targetID, value: value) }
        )
    }

    private func editMeeting(_ meeting: MeetingFeatureContext, kind: MeetingEditKind, targetID: String, value: String) {
        do {
            try meeting.edit(recording, kind: kind, targetID: targetID, value: value)
            meetingMessage = String(localized: "Meeting edit saved.")
        } catch {
            meetingMessage = error.localizedDescription
        }
    }

    private func handleEvidenceRequestIfNeeded() {
        guard let meeting = model.meeting, let evidenceRequest = meeting.evidenceRequest,
              evidenceRequest.recordingID == recording.id,
              evidenceRequest.id != handledEvidenceRequestID else { return }
        handledEvidenceRequestID = evidenceRequest.id
        selectedTab = .meeting
        Task {
            await meeting.load(recording)
            playTurns(evidenceRequest.turnIDs, meeting: meeting)
            meeting.clearEvidenceRequest(evidenceRequest.id)
        }
    }

    private func playTurns(_ turnIDs: [String], meeting: MeetingFeatureContext) {
        guard !meeting.enrollmentIsBusy, !model.recorder.isRecording, !model.recorder.isBusy,
              let content = meeting.resolved(recording), let library = model.library else { return }
        let selected = Set(turnIDs)
        let turns = content.transcript.turns.filter { selected.contains($0.id) }
        let audioURL = library.audioURL(for: recording)
        let controller = segmentPlayback ?? MeetingSegmentPlayback(
            position: { model.player.exactCurrentTime },
            isPlaying: { model.player.exactIsPlaying },
            playAt: { owner, time in try model.player.playSegment(recording: recording, url: audioURL, at: time, owner: owner) },
            seek: { owner, time in model.player.seekSegment(recordingID: recording.id, owner: owner, to: time) },
            pause: { owner in model.player.stopSegment(recordingID: recording.id, owner: owner) },
            stop: { owner in model.player.stopSegment(recordingID: recording.id, owner: owner) }
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
