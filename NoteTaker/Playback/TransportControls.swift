import SwiftUI

struct TransportControls: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        HStack(spacing: 16) {
            Button {
                Task { await controller.skipBackward() }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Back 15 Seconds"))
            .accessibilityIdentifier("back-15-button")
            .help(String(localized: "Back 15 Seconds"))

            Button {
                Task { await controller.togglePlayPause() }
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 44)
                    .background(.secondary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? String(localized: "Pause Playback") : String(localized: "Play"))
            .accessibilityValue(controller.isPlaying ? String(localized: "Playing") : String(localized: "Paused"))
            .accessibilityIdentifier("play-pause-button")
            .help(controller.isPlaying ? String(localized: "Pause Playback") : String(localized: "Play"))

            Button {
                Task { await controller.skipForward() }
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Forward 15 Seconds"))
            .accessibilityIdentifier("forward-15-button")
            .help(String(localized: "Forward 15 Seconds"))
        }
    }
}
