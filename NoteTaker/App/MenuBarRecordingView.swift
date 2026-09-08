import AppKit
import SwiftUI

struct MenuBarRecordingLabel: View {
    let session: RecordingSession?
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if let session, session.phase != .idle {
                Text(DurationFormat.list(session.elapsed(at: now)))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("AI-NoteTaker")
        .accessibilityValue(session?.phase.menuBarStatus ?? String(localized: "Loading..."))
        .help("AI-NoteTaker")
        .task(id: session?.phase) {
            now = .now
            guard session?.phase == .recording || session?.phase == .resuming else { return }
            // TimelineView in a status-item label can repeatedly invalidate
            // MenuBarExtraHost during launch. Keep label updates explicit and bounded.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                now = .now
            }
        }
    }

    private var symbol: String {
        if session?.alert != nil { return "exclamationmark.circle" }
        switch session?.phase {
        case .recording: return "record.circle.fill"
        case .paused, .pausing: return "pause.circle.fill"
        case .preparing, .resuming, .finishing: return "ellipsis.circle"
        default: return "waveform.circle"
        }
    }
}

struct MenuBarRecordingView: View {
    let container: AppContainer?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI-NoteTaker", systemImage: "waveform.circle.fill")
                    .font(.headline)
                Spacer()
                if let session = container?.session {
                    Text(session.phase.menuBarStatus)
                        .font(.caption)
                        .foregroundStyle(session.phase == .recording ? .red : .secondary)
                }
            }

            if let container {
                captureControls(container)
                if container.session.phase == .recording, container.meeting.profile.localVoice != nil {
                    OwnerSpeechIndicatorView(state: container.meeting.voice.state, compact: true)
                }
                if let alert = container.session.alert {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Recording Error"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                        Text(alert.displayMessage)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("menu-bar-error")
                        HStack {
                            if let url = alert.settingsURL {
                                Button(String(localized: "Open Settings")) { openURL(url) }
                            }
                            Button(String(localized: "Dismiss")) { container.session.dismissAlert() }
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                ProgressView(String(localized: "Loading..."))
                    .controlSize(.small)
            }

            Divider()
            Button {
                dismiss()
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label(String(localized: "Open AI-NoteTaker"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("menu-bar-open-window")

            HStack {
                Button(String(localized: "Settings...")) {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
                .disabled(container == nil)
                Spacer()
                Button(String(localized: "Quit AI-NoteTaker")) { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 292)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-panel")
    }

    @ViewBuilder
    private func captureControls(_ container: AppContainer) -> some View {
        let session = container.session
        if session.phase == .idle {
            Text(container.settings.captureMode.localizedLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await container.libraryController.startNewRecording() }
            } label: {
                Label(String(localized: "Start Recording"), systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityIdentifier("menu-bar-start")
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationFormat.list(session.elapsed(at: context.date)))
                    .font(.system(size: 30, weight: .light, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("menu-bar-elapsed")
            }
            HStack(spacing: 10) {
                if session.phase == .paused {
                    Button {
                        Task { await session.resume() }
                    } label: {
                        Label(String(localized: "Resume"), systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("menu-bar-resume")
                } else {
                    Button {
                        Task { await session.pause() }
                    } label: {
                        Label(String(localized: "Pause"), systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(session.phase != .recording)
                    .accessibilityIdentifier("menu-bar-pause")
                }
                Button {
                    Task { await session.finish() }
                } label: {
                    Label(String(localized: "Done"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.phase != .recording && session.phase != .paused)
                .accessibilityLabel(String(localized: "Finish Recording"))
                .accessibilityIdentifier("menu-bar-finish")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

private extension RecordingSessionPhase {
    var menuBarStatus: String {
        switch self {
        case .idle: String(localized: "Ready")
        case .preparing: String(localized: "Preparing...")
        case .recording: String(localized: "Recording")
        case .pausing: String(localized: "Pausing...")
        case .paused: String(localized: "Paused")
        case .resuming: String(localized: "Resuming...")
        case .finishing: String(localized: "Finishing...")
        }
    }
}
