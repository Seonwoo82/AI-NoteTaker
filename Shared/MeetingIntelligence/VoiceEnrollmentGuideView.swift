import SwiftUI

nonisolated struct VoiceEnrollmentGuidePolicy: Equatable {
    var minimumDuration: Double = OwnerVoicePolicy().minimumEnrollmentDuration
    var maximumDuration: Double = OwnerVoicePolicy().maximumEnrollmentDuration

    func canFinish(elapsed: Double, detectedAudioDuration: Double? = nil) -> Bool {
        elapsed >= minimumDuration && (detectedAudioDuration.map { $0 >= min(3, minimumDuration) } ?? true)
    }

    func progress(elapsed: Double) -> Double {
        guard maximumDuration > 0 else { return 0 }
        return min(max(elapsed / maximumDuration, 0), 1)
    }

    func remainingMinimumSeconds(elapsed: Double) -> Int {
        max(0, Int(ceil(minimumDuration - elapsed)))
    }
}

struct VoiceEnrollmentGuideView: View {
    let voice: VoiceProfilePresentation
    let hasExistingProfile: Bool
    let recordingIsBusy: Bool
    let isStarting: Bool
    let isCompleted: Bool
    var policy = VoiceEnrollmentGuidePolicy()
    let onStart: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label(String(localized: "Record My Voice"), systemImage: "waveform.and.mic")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close"))
                    .accessibilityIdentifier("voice-enrollment-close")
                }

                Text(String(localized: "Read the guide below in your normal meeting voice. Keep the device about 20 to 30 cm from your mouth and choose a quiet room."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice-enrollment-guidance")

                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "Please read aloud"), systemImage: "text.quote")
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "Hello, this is my voice for AI-NoteTaker. I usually speak in meetings about project goals, next steps, decisions, questions, and follow-up work. Please use this short sample to recognize when I am speaking."))
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice-enrollment-prompt")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))

                Text(String(localized: "Save after \(Int(policy.minimumDuration))s · stops at \(Int(policy.maximumDuration))s"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if voice.isEnrolling || voice.isProcessing || voice.elapsed > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: policy.progress(elapsed: voice.elapsed))
                            .accessibilityIdentifier("voice-enrollment-progress")
                        HStack {
                            Text(ProfileDurationFormat.short(voice.elapsed))
                                .monospacedDigit()
                                .accessibilityIdentifier("voice-enrollment-elapsed")
                            Spacer()
                            if voice.isEnrolling {
                                Label(String(localized: "Recording"), systemImage: "record.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        if !policy.canFinish(elapsed: voice.elapsed), voice.isEnrolling {
                            Text(String(localized: "\(policy.remainingMinimumSeconds(elapsed: voice.elapsed)) more seconds of clear speech before saving."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("voice-enrollment-minimum")
                        }
                    }
                }

                if voice.isEnrolling, let inputLevel = voice.inputLevel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Microphone input"), systemImage: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                        ProgressView(value: inputLevel)
                            .tint(inputLevel > 0.15 ? .green : .orange)
                            .accessibilityLabel(String(localized: "Microphone input level"))
                            .accessibilityIdentifier("voice-enrollment-input-meter")
                        Text(String(localized: "Audio detected: \(Int(voice.detectedAudioDuration)) seconds"))
                            .font(.caption).foregroundStyle(.secondary)
                        if voice.elapsed >= 3, voice.detectedAudioDuration < 1 {
                            Text(String(localized: "The microphone input is very low. Move closer and check that the microphone is not covered."))
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if isCompleted {
                    Label(String(localized: "Voice profile saved on this device."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("voice-enrollment-success")
                } else if isStarting || !voice.status.isEmpty || voice.isProcessing {
                    HStack {
                        if isStarting || voice.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isStarting ? String(localized: "Starting voice recording...") : voice.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice-enrollment-status")
                    }
                }

                if let error = voice.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice-enrollment-error")
                }

                buttons
                    .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .frame(minWidth: 320, maxWidth: 460)
        .accessibilityIdentifier("voice-enrollment-guide")
    }

    @ViewBuilder
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if voice.isEnrolling {
            Button {
                onFinish()
            } label: {
                Label(hasExistingProfile ? String(localized: "Update Voice") : String(localized: "Save Voice"),
                      systemImage: "checkmark.circle")
            }
            .disabled(!policy.canFinish(elapsed: voice.elapsed,
                detectedAudioDuration: voice.inputLevel == nil ? nil : voice.detectedAudioDuration) || voice.isProcessing || isStarting)
            .accessibilityIdentifier("voice-enrollment-finish")

            Button(role: .cancel) {
                onCancel()
            } label: {
                Label(String(localized: "Cancel"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("voice-enrollment-cancel")
        } else if voice.isProcessing || isStarting {
            Button(role: .cancel) {
                onCancel()
            } label: {
                Label(String(localized: "Cancel"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier(isStarting ? "voice-enrollment-cancel-starting" : "voice-enrollment-cancel-processing")
        } else if isCompleted {
            Button {
                onClose()
            } label: {
                Label(String(localized: "Close"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("voice-enrollment-close-completed")
        } else {
            Button {
                onStart()
            } label: {
                Label(voice.error == nil ? String(localized: "Start Recording") : String(localized: "Re-record"),
                      systemImage: "record.circle")
            }
            .disabled(recordingIsBusy || !voice.modelsReady || voice.isPreparing || isStarting)
            .accessibilityIdentifier("voice-enrollment-start")

            Button(role: .cancel) {
                onClose()
            } label: {
                Label(String(localized: "Close"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("voice-enrollment-cancel")
        }
    }
}

extension View {
    @ViewBuilder
    func presentationDetentsForVoiceEnrollment() -> some View {
#if os(iOS)
        self.presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        self.frame(width: 460, height: 580)
#endif
    }
}
