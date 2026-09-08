import SwiftUI

struct RecordingDetailTabsView: View {
    let model: LibraryAppModel
    let recording: Recording
    let openAISettings: () -> Void
    @State private var showsNotes = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Recording Detail", selection: $showsNotes) {
                Label("Audio", systemImage: "waveform").tag(false)
                Label("AI Meeting Notes", systemImage: "sparkles").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("recording-detail-tabs")

            if let notes = model.meetingNotes, showsNotes {
                MeetingNotesView(recording: recording, service: notes,
                                 configuration: model.aiConfiguration,
                                 openAISettings: openAISettings)
            } else {
                RecordingDetailView(model: model, recording: recording)
                if let notes = model.meetingNotes {
                    if notes.progress(for: recording.id).isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("AI meeting notes are being prepared.")
                            Button("View Notes") { showsNotes = true }
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                    } else if notes.document(for: recording.id) != nil {
                        Button("View AI Meeting Notes") { showsNotes = true }
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .navigationTitle("Recording")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: recording.id) { await model.meetingNotes?.load(recording) }
    }
}
