import SwiftUI

struct RecordingDetailView: View {
    let model: LibraryAppModel
    let recording: Recording
    @State private var title = ""
    @State private var renaming = false

    private var isCurrent: Bool { model.player.recordingID == recording.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: recording.deletedAt == nil ? "waveform.circle.fill" : "trash.circle.fill")
                    .font(.system(size: 76, weight: .ultraLight)).foregroundStyle(.red.gradient)
                    .accessibilityHidden(true).padding(.top, 36)
                VStack(spacing: 10) {
                    Text(recording.title).font(.title.bold()).multilineTextAlignment(.center)
                    Text(recording.createdAt, format: .dateTime.year().month(.wide).day().hour().minute())
                        .foregroundStyle(.secondary)
                    Label(recording.mode == .micOnly ? "Microphone" : "System Audio", systemImage: recording.mode == .micOnly ? "mic" : "speaker.wave.2")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if recording.deletedAt == nil {
                    playbackControls
                } else {
                    Text("This recording is in Recently Deleted. Restore it to listen again.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Restore Recording", systemImage: "arrow.uturn.backward") {
                        model.edit(recording) { $0.deletedAt = nil }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !recording.warnings.isEmpty {
                    ForEach(recording.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }
                Spacer(minLength: 30)
            }
            .padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .navigationTitle("Recording")
        .toolbar {
            if recording.deletedAt == nil {
                Button {
                    model.edit(recording) { $0.isFavorite.toggle() }
                } label: {
                    Label(recording.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: recording.isFavorite ? "star.fill" : "star")
                }
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        title = recording.title
                        renaming = true
                    }
                    Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                        model.edit(recording) { $0.deletedAt = .now }
                    }
                } label: {
                    Label("Recording Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Recording", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.edit(recording) { $0.title = String(trimmed.prefix(500)) } }
            }
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { isCurrent ? model.player.currentTime : 0 },
                    set: { model.player.seek(to: $0) }
                ), in: 0...max(isCurrent ? model.player.duration : recording.duration, 0.1))
                .disabled(!isCurrent).accessibilityLabel("Playback Position")
                HStack {
                    Text(DurationFormat.list(isCurrent ? model.player.currentTime : 0))
                    Spacer()
                    Text(DurationFormat.list(isCurrent ? model.player.duration : recording.duration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 36) {
                Button { model.player.seek(to: model.player.currentTime - 15) } label: {
                    Label("Back 15 Seconds", systemImage: "gobackward.15").labelStyle(.iconOnly)
                }
                .disabled(!isCurrent)
                Button {
                    if isCurrent && model.player.isPlaying { model.player.pause() }
                    else { model.play(recording) }
                } label: {
                    Label(isCurrent && model.player.isPlaying ? "Pause" : "Play", systemImage: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly).font(.title).foregroundStyle(.white)
                        .frame(width: 68, height: 68).background(.red, in: Circle())
                }
                .buttonStyle(.plain).disabled(model.recorder.isRecording || model.recorder.isBusy)
                .accessibilityIdentifier("play-recording-button")
                Button { model.player.seek(to: model.player.currentTime + 15) } label: {
                    Label("Forward 15 Seconds", systemImage: "goforward.15").labelStyle(.iconOnly)
                }
                .disabled(!isCurrent)
            }
            .font(.title2).buttonStyle(.plain)
        }
    }
}
