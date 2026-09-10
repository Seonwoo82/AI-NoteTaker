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
                recordingStatus
                recordingActions
                if model.recorder.hasPendingRecording {
                    Text("Audio stays on this device and will be recovered the next time you open the app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var recordingStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                recordingTime.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                ownerIndicator.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                recordingTime
                ownerIndicator
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("recording-status-area")
    }

    private var recordingTime: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.recorder.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(model.recorder.isPaused || model.recorder.hasPendingRecording ? Color.orange : Color.red)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(recordingStatusTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(DurationFormat.list(model.recorder.elapsed))
                .font(.title2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("recording-elapsed-time")
        }
    }

    private var recordingStatusTitle: LocalizedStringKey {
        if model.recorder.hasPendingRecording { return "Save Pending" }
        if model.recorder.isBusy { return model.recorder.elapsed > 0 ? "Saving recording…" : "Preparing..." }
        return model.recorder.isPaused ? "Paused" : "Recording"
    }

    @ViewBuilder
    private var ownerIndicator: some View {
        if model.recorder.isRecording, !model.recorder.isPaused, let meeting = model.meeting {
            OwnerSpeechIndicatorView(state: meeting.voice.state, compact: true)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { secondaryRecordingAction; finishRecordingAction }
            VStack(spacing: 10) { secondaryRecordingAction; finishRecordingAction }
        }
        .disabled(model.recorder.isBusy)
        .opacity(model.recorder.isBusy ? 0.55 : 1)
    }

    @ViewBuilder
    private var secondaryRecordingAction: some View {
        if model.recorder.hasPendingRecording {
            Button { model.recorder.deferPendingSave() } label: {
                actionLabel("Keep for Later", symbol: "clock")
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("defer-recording-save-button")
        } else if model.recorder.canPause {
            Button {
                if model.recorder.isPaused { model.recorder.resume() }
                else { model.recorder.pause() }
            } label: {
                actionLabel(model.recorder.isPaused ? "Resume" : "Pause",
                            symbol: model.recorder.isPaused ? "mic.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("pause-resume-recording-button")
        }
    }

    private var finishRecordingAction: some View {
        Button { Task { await model.finishRecording() } } label: {
            actionLabel(model.recorder.hasPendingRecording ? "Retry Save" : "Done",
                        symbol: model.recorder.hasPendingRecording ? "arrow.clockwise" : "stop.fill")
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("finish-recording-button")
    }

    private func actionLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol)
                .fixedSize(horizontal: true, vertical: false)
            Text(title)
                .fixedSize(horizontal: true, vertical: false)
        }
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
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
