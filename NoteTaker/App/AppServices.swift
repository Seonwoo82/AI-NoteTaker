import AudioPipeline
import Foundation

@MainActor
struct AppServices {
    let recorder: any RecorderEngine
    let player: any PlayerEngine
    let audioDeviceProvider: any AudioDeviceProviding
    var aiEnvironment: AIEnvironment? = nil

    static func live() -> AppServices {
        AppServices(
            recorder: AudioPipelineRecorderEngine(),
            player: AudioPipelinePlayerEngine(),
            audioDeviceProvider: SystemAudioDeviceProvider(),
            aiEnvironment: .live()
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
            aiEnvironment: .testing(configured: ProcessInfo.processInfo.arguments.contains("-uiTestingAI"))
        )
    }
}
