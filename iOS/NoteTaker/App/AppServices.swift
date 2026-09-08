import Foundation

@MainActor
struct AppServices {
    let recorder: VoiceRecorder
    let player: VoicePlayer

    static func live() -> AppServices {
        AppServices(
            recorder: VoiceRecorder(),
            player: VoicePlayer()
        )
    }

    static func uiTesting() -> AppServices {
        live()
    }
}
