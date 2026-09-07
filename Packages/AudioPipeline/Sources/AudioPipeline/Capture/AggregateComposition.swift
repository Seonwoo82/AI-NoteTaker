import CoreAudio
import Foundation

public enum AggregateClockSource: Equatable, Sendable {
    case microphone
    case output
}

public struct AggregateSubDevice: Equatable, Sendable {
    public let uid: String
    public let driftCompensation: Bool

    public init(uid: String, driftCompensation: Bool) {
        self.uid = uid
        self.driftCompensation = driftCompensation
    }
}

public enum AggregateCompositionError: Error, Equatable, Sendable {
    case missingMicrophoneUID
    case missingOutputUID
    case missingTapUID
}

public struct AggregateComposition: Equatable, Sendable {
    public let mode: CaptureMode
    public let clockSource: AggregateClockSource
    public let mainSubDeviceUID: String
    public let subDevices: [AggregateSubDevice]
    public let tapUID: UUID?
    public let tapAutoStart: Bool

    public init(
        mode: CaptureMode,
        microphoneUID: String?,
        outputUID: String?,
        tapUID: UUID?,
        clockSource: AggregateClockSource = .microphone
    ) throws {
        self.mode = mode

        switch mode {
        case .micOnly:
            guard let microphoneUID = microphoneUID?.requiredUID else {
                throw AggregateCompositionError.missingMicrophoneUID
            }
            self.clockSource = .microphone
            self.mainSubDeviceUID = microphoneUID
            self.subDevices = [AggregateSubDevice(uid: microphoneUID, driftCompensation: true)]
            self.tapUID = nil
            self.tapAutoStart = false

        case .micAndSystem:
            guard let microphoneUID = microphoneUID?.requiredUID else {
                throw AggregateCompositionError.missingMicrophoneUID
            }
            guard let outputUID = outputUID?.requiredUID else {
                throw AggregateCompositionError.missingOutputUID
            }
            guard let tapUID else {
                throw AggregateCompositionError.missingTapUID
            }

            self.clockSource = clockSource
            switch clockSource {
            case .microphone:
                self.mainSubDeviceUID = microphoneUID
                self.subDevices = [AggregateSubDevice(uid: microphoneUID, driftCompensation: true)]
            case .output:
                self.mainSubDeviceUID = outputUID
                self.subDevices = [
                    AggregateSubDevice(uid: outputUID, driftCompensation: false),
                    AggregateSubDevice(uid: microphoneUID, driftCompensation: true)
                ]
            }
            self.tapUID = tapUID
            self.tapAutoStart = false

        case .systemOnly:
            guard let outputUID = outputUID?.requiredUID else {
                throw AggregateCompositionError.missingOutputUID
            }
            guard let tapUID else {
                throw AggregateCompositionError.missingTapUID
            }

            self.clockSource = .output
            self.mainSubDeviceUID = outputUID
            self.subDevices = [AggregateSubDevice(uid: outputUID, driftCompensation: false)]
            self.tapUID = tapUID
            self.tapAutoStart = true
        }
    }

    public func makeHALProperties(name: String, uid: String) -> [String: Any] {
        var properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: mainSubDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices.map { subDevice in
                [
                    kAudioSubDeviceUIDKey: subDevice.uid,
                    kAudioSubDeviceDriftCompensationKey: subDevice.driftCompensation
                ] as [String: Any]
            },
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: tapAutoStart
        ]

        if let tapUID {
            properties[kAudioAggregateDeviceTapListKey] = [
                [
                    kAudioSubTapUIDKey: tapUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ] as [String: Any]
            ]
        }

        return properties
    }
}

private extension String {
    var requiredUID: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
