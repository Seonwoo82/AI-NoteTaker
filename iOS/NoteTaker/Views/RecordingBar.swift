import SwiftUI
#if canImport(AudioPipeline)
import AudioPipeline
#endif

struct RecordingBar: View {
    let model: LibraryAppModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            if model.recorder.isRecording || model.recorder.isBusy || model.recorder.hasPendingRecording {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.recorder.hasPendingRecording ? "Save Pending" : (model.recorder.isPaused ? "Paused" : "Recording"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(DurationFormat.list(model.recorder.elapsed))
                            .font(.title2.monospacedDigit().weight(.semibold))
                    }
                    Spacer()
                    if model.recorder.isRecording, let meeting = model.meeting {
                        OwnerSpeechIndicatorView(state: meeting.voice.state, compact: true)
                    }
                    if model.recorder.hasPendingRecording {
                        Button("Keep for Later") { model.recorder.deferPendingSave() }
                            .buttonStyle(.bordered)
                    }
                    if model.recorder.canPause && !model.recorder.hasPendingRecording {
                        Button {
                            if model.recorder.isPaused { model.recorder.resume() }
                            else { model.recorder.pause() }
                        } label: {
                            Label(model.recorder.isPaused ? "Resume" : "Pause", systemImage: model.recorder.isPaused ? "mic.fill" : "pause.fill")
                        }
                        .disabled(model.recorder.isBusy)
                    }
                    Button { Task { await model.finishRecording() } } label: {
                        Label(model.recorder.hasPendingRecording ? "Retry Save" : "Done", systemImage: model.recorder.hasPendingRecording ? "arrow.clockwise" : "stop.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.recorder.isBusy)
                    .accessibilityIdentifier("finish-recording-button")
                }
                if model.recorder.hasPendingRecording {
                    Text("Audio stays on this device and will be recovered the next time you open the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Capture a thought").font(.headline)
                        syncStatus
                    }
                    Spacer(minLength: 8)
                    #if os(macOS)
                    Picker("Audio Source", selection: $model.captureMode) {
                        Text("Microphone").tag(CaptureMode.micOnly)
                        Text("System Audio").tag(CaptureMode.systemOnly)
                    }
                    .labelsHidden().frame(maxWidth: 160)
                    #endif
                    Button { Task { await model.startRecording() } } label: {
                        Image(systemName: "mic.fill")
                            .font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Recording")
                    .accessibilityIdentifier("new-recording-button")
                    .disabled(model.library == nil)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if model.sync.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if model.sync.errorMessage != nil {
            Label("Sync needs attention in Settings", systemImage: "exclamationmark.icloud")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label(model.settings.isEnabled ? "Cloudflare sync enabled" : "Saved on this device", systemImage: model.settings.isEnabled ? "icloud" : "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
