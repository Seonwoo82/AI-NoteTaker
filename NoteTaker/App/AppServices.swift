import AudioPipeline
import Foundation

@MainActor
struct AppServices {
    let recorder: any RecorderEngine
    let player: any PlayerEngine
    let audioDeviceProvider: any AudioDeviceProviding
    var aiEnvironment: AIEnvironment? = nil
    var syncSettings: SyncSettings = SyncSettings()

    static func live() -> AppServices {
        AppServices(
            recorder: AudioPipelineRecorderEngine(),
            player: AudioPipelinePlayerEngine(),
            audioDeviceProvider: SystemAudioDeviceProvider(),
            aiEnvironment: .live(),
            syncSettings: SyncSettings()
        )
    }

    static func uiTesting() -> AppServices {
        AppServices(
            recorder: FakeRecorderEngine(),
            player: FakePlayerEngine(),
            audioDeviceProvider: StaticAudioDeviceProvider(
                inputDevices: [
                    AudioDeviceInfo(id: 11, uid: "ui-built-in", name: "Built-in Microphone", transportType: 0, inputChannelCount: 2),
                    AudioDeviceInfo(id: 22, uid: "ui-usb", name: "USB Microphone", transportType: 0, inputChannelCount: 1)
                ],
                defaultInputDeviceUID: "ui-built-in"
            ),
            aiEnvironment: .testing(configured: ProcessInfo.processInfo.arguments.contains("-uiTestingAI")),
            syncSettings: SyncSettings(defaults: UserDefaults(suiteName: "NoteTakerUITesting-\(UUID().uuidString)") ?? .standard,
                                       tokenStore: MemorySyncTokenStore())
        )
    }
}

@MainActor
private final class MemorySyncTokenStore: SyncTokenStore {
    private var token: String?

    func loadToken() throws -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }
}
