import SwiftUI

struct RecordingDetailTabsView: View {
    let recording: Recording
    let playback: PlaybackController
    let libraryController: LibraryController
    let meetingNotes: MeetingNotesService
    let aiConfiguration: AIConfiguration
    @State private var showsNotes = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Recording Detail"), selection: $showsNotes) {
                Label(String(localized: "Audio"), systemImage: "waveform").tag(false)
                Label(String(localized: "AI Meeting Notes"), systemImage: "sparkles").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityIdentifier("recording-detail-tabs")

            if showsNotes {
                MeetingNotesView(recording: recording, service: meetingNotes, configuration: aiConfiguration)
            } else {
                PlaybackDetailView(recording: recording, controller: playback, libraryController: libraryController)
                if meetingNotes.progress(for: recording.id).isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "AI meeting notes are being prepared."))
                        Button(String(localized: "View Notes")) { showsNotes = true }
                    }
                    .font(.caption)
                    .padding(.bottom, 12)
                } else if meetingNotes.document(for: recording.id) != nil {
                    Button(String(localized: "View AI Meeting Notes")) { showsNotes = true }
                        .buttonStyle(.borderless)
                        .padding(.bottom, 12)
                }
            }
        }
        .task(id: recording.id) { await meetingNotes.load(recording) }
    }
}
