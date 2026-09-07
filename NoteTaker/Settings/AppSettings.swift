import AudioPipeline
import Foundation
import Observation

@MainActor
protocol AudioDeviceProviding: Sendable {
    func inputDevices() -> [AudioDeviceInfo]
    func defaultInputDeviceUID() -> String?
}

struct SystemAudioDeviceProvider: AudioDeviceProviding {
    func inputDevices() -> [AudioDeviceInfo] {
        (try? AudioDeviceRegistry().inputDevices()) ?? []
    }

    func defaultInputDeviceUID() -> String? {
        let registry = AudioDeviceRegistry()
        guard let id = try? registry.defaultInputDeviceID() else { return nil }
        return try? registry.uid(forDeviceID: id)
    }
}

struct StaticAudioDeviceProvider: AudioDeviceProviding {
    let devices: [AudioDeviceInfo]
    let defaultUID: String?

    init(inputDevices: [AudioDeviceInfo], defaultInputDeviceUID: String?) {
        self.devices = inputDevices
        self.defaultUID = defaultInputDeviceUID
    }

    func inputDevices() -> [AudioDeviceInfo] {
        devices
    }

    func defaultInputDeviceUID() -> String? {
        defaultUID
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let captureMode = "captureMode"
        static let microphoneUID = "microphoneUID"
        static let microphoneGain = "microphoneGain"
        static let systemGain = "systemGain"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let audioDeviceProvider: any AudioDeviceProviding

    var captureMode: CaptureMode {
        didSet {
            defaults.set(captureMode.rawValue, forKey: Keys.captureMode)
        }
    }

    var microphoneUID: String? {
        didSet {
            if let microphoneUID {
                defaults.set(microphoneUID, forKey: Keys.microphoneUID)
            } else {
                defaults.removeObject(forKey: Keys.microphoneUID)
            }
        }
    }

    private(set) var inputDevices: [AudioDeviceInfo]
    private(set) var defaultMicrophoneUID: String?
    var microphoneGain: Float {
        didSet {
            let sanitized = Self.sanitizedGain(microphoneGain)
            guard sanitized == microphoneGain else {
                microphoneGain = sanitized
                return
            }
            defaults.set(microphoneGain, forKey: Keys.microphoneGain)
        }
    }

    var systemGain: Float {
        didSet {
            let sanitized = Self.sanitizedGain(systemGain)
            guard sanitized == systemGain else {
                systemGain = sanitized
                return
            }
            defaults.set(systemGain, forKey: Keys.systemGain)
        }
    }

    var selectedMicrophoneUID: String? {
        microphoneUID ?? defaultMicrophoneUID
    }

    init(
        defaults: UserDefaults = .standard,
        audioDeviceProvider: any AudioDeviceProviding = SystemAudioDeviceProvider()
    ) {
        self.defaults = defaults
        self.audioDeviceProvider = audioDeviceProvider
        if let rawValue = defaults.string(forKey: Keys.captureMode),
           let mode = CaptureMode(rawValue: rawValue) {
            captureMode = mode
        } else {
            captureMode = .micAndSystem
        }
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        microphoneGain = Self.sanitizedGain(defaults.object(forKey: Keys.microphoneGain))
        systemGain = Self.sanitizedGain(defaults.object(forKey: Keys.systemGain))
        inputDevices = audioDeviceProvider.inputDevices()
        defaultMicrophoneUID = audioDeviceProvider.defaultInputDeviceUID()
    }

    func refreshInputDevices() {
        inputDevices = audioDeviceProvider.inputDevices()
        defaultMicrophoneUID = audioDeviceProvider.defaultInputDeviceUID()
    }

    nonisolated private static func sanitizedGain(_ rawValue: Any?) -> Float {
        let value: Float?
        switch rawValue {
        case let float as Float:
            value = float
        case let double as Double:
            value = Float(double)
        case let number as NSNumber:
            value = number.floatValue
        default:
            value = nil
        }
        guard let value, value.isFinite else { return 1 }
        return min(2, max(0, value))
    }

    nonisolated private static func sanitizedGain(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(2, max(0, value))
    }
}
