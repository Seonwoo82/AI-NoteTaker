import AudioPipeline
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let session: RecordingSession

    private var isRecordingActive: Bool {
        session.phase != .idle
    }

    var body: some View {
        Form {
            Section(String(localized: "Recording")) {
                Picker(String(localized: "Capture Mode"), selection: $settings.captureMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { mode in
                        Text(mode.localizedLabel).tag(mode)
                    }
                }

                Picker(String(localized: "Microphone"), selection: microphoneBinding) {
                    Text(String(localized: "Default Microphone")).tag("")
                    ForEach(settings.inputDevices) { device in
                        Text(device.displayName(defaultUID: settings.defaultMicrophoneUID)).tag(device.uid)
                    }
                }

                Button(String(localized: "Refresh Devices")) {
                    settings.refreshInputDevices()
                }
            }
            .disabled(isRecordingActive)

            Section(String(localized: "Levels")) {
                GainSlider(title: String(localized: "Microphone Gain"), value: $settings.microphoneGain)
                GainSlider(title: String(localized: "System Gain"), value: $settings.systemGain)
            }
            .disabled(isRecordingActive)

            if isRecordingActive {
                Text(String(localized: "Capture changes are available after the current recording finishes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var microphoneBinding: Binding<String> {
        Binding(
            get: { settings.microphoneUID ?? "" },
            set: { settings.microphoneUID = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct GainSlider: View {
    let title: String
    @Binding var value: Float

    var body: some View {
        HStack {
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Float($0) }
            ), in: 0...2, step: 0.05) {
                Text(title)
            }
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
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
