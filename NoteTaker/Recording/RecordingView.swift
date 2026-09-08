import SwiftUI

struct RecordingView: View {
    let session: RecordingSession
    let settings: AppSettings
    @Bindable var playback: PlaybackController
    var ownerSpeechState: OwnerSpeechState? = nil

    private var statusText: String {
        switch session.phase {
        case .preparing:
            String(localized: "Preparing...")
        case .finishing:
            String(localized: "Finishing...")
        case .recording:
            String(localized: "Recording")
        case .pausing:
            String(localized: "Pausing...")
        case .paused:
            String(localized: "Paused")
        case .resuming:
            String(localized: "Resuming...")
        case .idle:
            String(localized: "Ready")
        }
    }

    private var isFinishing: Bool {
        session.phase == .finishing
    }

    private var canPause: Bool {
        session.phase == .recording
    }

    private var canResume: Bool {
        session.phase == .paused
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(String(localized: "New Recording"))
                .font(.system(size: 17, weight: .medium))
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(DurationFormat.timer(session.elapsed(at: context.date), total: 0))
                    .font(.system(size: 31, weight: .regular, design: .monospaced))
                    .minimumScaleFactor(0.75)
            }
            Text(settings.captureMode.localizedLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityIdentifier("recording-status-label")
            if session.phase == .recording, let ownerSpeechState {
                OwnerSpeechIndicatorView(state: ownerSpeechState, compact: true)
            }

            Spacer(minLength: 8)

            Group {
                if session.phase == .paused {
                    WaveformView(
                        peaks: playback.waveformPeaks,
                        currentTime: playback.currentTime,
                        duration: playback.duration,
                        onSeek: { time in Task { await playback.seek(to: time) } }
                    )
                    .accessibilityIdentifier("pause-preview-waveform")
                } else {
                    VStack(spacing: 20) {
                        if settings.captureMode != .systemOnly {
                            inputMeter(label: String(localized: "Microphone"), icon: "mic.fill", peak: session.microphonePeak)
                        }
                        if settings.captureMode != .micOnly {
                            inputMeter(label: String(localized: "System Audio"), icon: "speaker.wave.2.fill", peak: session.systemPeak)
                        }
                    }
                    .accessibilityIdentifier("live-capture-rail")
                }
            }
            .frame(maxWidth: 570)
            .frame(height: 126)

            Spacer(minLength: 4)

            if session.phase == .paused {
                VStack(spacing: 4) {
                    TransportControls(controller: playback)
                    Text(DurationFormat.timer(playback.currentTime, total: playback.duration))
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("preview-time-label")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pause-preview-transport")
            }

            HStack(spacing: 10) {
                Button(String(localized: "Pause")) {
                    Task {
                        await session.pause()
                    }
                }
                .controlSize(.large)
                .disabled(!canPause)
                .accessibilityIdentifier("pause-recording-button")

                Button(String(localized: "Resume")) {
                    Task {
                        await session.resume()
                    }
                }
                .controlSize(.large)
                .disabled(!canResume)
                .accessibilityIdentifier("resume-recording-button")

                Button(String(localized: "Done")) {
                    Task {
                        await session.finish()
                    }
                }
                .controlSize(.large)
                .disabled(isFinishing || session.phase == .preparing)
                .accessibilityIdentifier("done-recording-button")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-view")
    }

    private func inputMeter(label: String, icon: String, peak: Float) -> some View {
        let level = peak.isFinite ? Double(min(1, max(0, peak))) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Text(level > 0.001 ? String(localized: "Signal detected") : String(localized: "No signal"))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            ProgressView(value: level)
                .tint(.red)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(level * 100))%")
        }
    }
}
