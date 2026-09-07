import AudioPipeline
import SwiftUI

struct RecordButton: View {
    let session: RecordingSession
    @Bindable var settings: AppSettings
    var startAction: (() -> Void)?

    private var isBusy: Bool {
        session.phase == .preparing || session.phase == .finishing
    }

    var body: some View {
        Button {
            if let startAction {
                startAction()
            } else {
                Task { await session.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 64, height: 64)
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 58, height: 58)
                Circle()
                    .fill(Color.red)
                    .frame(width: 52, height: 52)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 72, height: 72)
        .disabled(isBusy || session.phase != .idle)
        .help(String(localized: "New Recording"))
        .accessibilityLabel(String(localized: "New Recording"))
        .accessibilityIdentifier("new-recording-button")
        .task {
            settings.refreshInputDevices()
        }
        .contextMenu {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    settings.captureMode = mode
                } label: {
                    Label(mode.localizedLabel, systemImage: mode == settings.captureMode ? "checkmark" : "")
                }
            }
            Divider()
            Button {
                settings.microphoneUID = nil
            } label: {
                Label(
                    String(localized: "Default Microphone"),
                    systemImage: settings.microphoneUID == nil ? "checkmark" : ""
                )
            }
            ForEach(settings.inputDevices) { device in
                Button {
                    settings.microphoneUID = device.uid
                } label: {
                    Label(
                        device.displayName(defaultUID: settings.defaultMicrophoneUID),
                        systemImage: device.uid == settings.microphoneUID ? "checkmark" : ""
                    )
                }
            }
        }
    }
}

private extension AudioDeviceInfo {
    func displayName(defaultUID: String?) -> String {
        if uid == defaultUID {
            return "\(name) \(String(localized: "(Default)"))"
        }
        return name
    }
}

extension CaptureMode {
    var localizedLabel: String {
        switch self {
        case .micAndSystem:
            String(localized: "Microphone + System")
        case .micOnly:
            String(localized: "Microphone Only")
        case .systemOnly:
            String(localized: "System Only")
        }
    }
}
