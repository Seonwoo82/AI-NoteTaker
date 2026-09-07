import AudioPipeline
import Foundation
import Observation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct AppSettingsTests {
    @Test("AppSettings defaults a fresh suite to microphone plus system capture")
    func defaultsFreshSuiteToMicrophonePlusSystemCapture() throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())

        #expect(settings.captureMode == .micAndSystem)
        #expect(settings.microphoneUID == nil)
        #expect(settings.microphoneGain == 1)
        #expect(settings.systemGain == 1)
    }

    @Test("AppSettings persists raw capture mode and optional microphone UID")
    func persistsRawCaptureModeAndOptionalMicrophoneUID() throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())

        settings.captureMode = .systemOnly
        settings.microphoneUID = "BuiltInMic"
        settings.microphoneGain = 1.5
        settings.systemGain = 0.25

        let reloaded = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())
        #expect(reloaded.captureMode == .systemOnly)
        #expect(reloaded.microphoneUID == "BuiltInMic")
        #expect(reloaded.microphoneGain == 1.5)
        #expect(reloaded.systemGain == 0.25)
    }

    @Test("AppSettings clamps finite gains and sanitizes invalid saved values")
    func clampsFiniteGainsAndSanitizesInvalidSavedValues() throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())

        settings.microphoneGain = 4
        settings.systemGain = -.infinity

        let reloaded = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())
        #expect(reloaded.microphoneGain == 2)
        #expect(reloaded.systemGain == 1)
    }

    @Test("AppSettings publishes observable persisted values")
    func publishesObservablePersistedValues() async throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults, audioDeviceProvider: emptyDeviceProvider())
        let counter = ObservationCounter()

        withObservationTracking {
            _ = settings.captureMode
            _ = settings.microphoneUID
        } onChange: {
            Task { @MainActor in
                counter.increment()
            }
        }
        settings.captureMode = .systemOnly
        await Task.yield()

        #expect(counter.count == 1)
    }

    @Test("AppSettings loads deterministic input devices and preserves persisted microphone selection")
    func loadsDeterministicInputDevicesAndPreservesPersistedMicrophoneSelection() throws {
        let defaults = try isolatedDefaults()
        let provider = StaticAudioDeviceProvider(
            inputDevices: [
                AudioDeviceInfo(id: 11, uid: "built-in", name: "Built-in Microphone", transportType: 0, inputChannelCount: 2),
                AudioDeviceInfo(id: 22, uid: "usb", name: "USB Microphone", transportType: 0, inputChannelCount: 1)
            ],
            defaultInputDeviceUID: "usb"
        )
        let settings = AppSettings(defaults: defaults, audioDeviceProvider: provider)

        #expect(settings.inputDevices.map(\.uid) == ["built-in", "usb"])
        #expect(settings.defaultMicrophoneUID == "usb")

        settings.microphoneUID = "built-in"
        let reloaded = AppSettings(defaults: defaults, audioDeviceProvider: provider)

        #expect(reloaded.microphoneUID == "built-in")
        #expect(reloaded.selectedMicrophoneUID == "built-in")
    }
}

@MainActor
private final class ObservationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func isolatedDefaults() throws -> UserDefaults {
    let suiteName = "NoteTakerAppSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private func emptyDeviceProvider() -> StaticAudioDeviceProvider {
    StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
}
