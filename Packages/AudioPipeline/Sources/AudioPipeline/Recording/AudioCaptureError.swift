import Foundation

public enum AudioCaptureOperation: Equatable, Sendable {
    case tapCreation
    case aggregateCreation
    case ioProcCreation
    case start
    case write
    case streamFormat
}

public enum AudioCaptureError: Error, Equatable, Sendable {
    case unsupportedCaptureMode(CaptureMode)
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case deviceNotFound(uid: String?)
    case unsupportedStreamFormat(OSStatus?)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)
    case outputAlreadyExists(String)
    case fileWriteFailed(String)
    case diskSpaceLow
    case deviceDisconnected
    case ioStoppedAbnormally
    case streamFormatChanged

    public var settingsURL: URL? {
        switch self {
        case .unsupportedCaptureMode:
            return nil
        case .microphonePermissionDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudioPermissionDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        default:
            return nil
        }
    }

    public var keepsPartialFile: Bool {
        switch self {
        case .outputAlreadyExists,
             .fileWriteFailed,
             .diskSpaceLow,
             .deviceDisconnected,
             .ioStoppedAbnormally,
             .streamFormatChanged:
            return true
        case .microphonePermissionDenied,
             .unsupportedCaptureMode,
             .systemAudioPermissionDenied,
             .tapCreationFailed,
             .aggregateCreationFailed,
             .deviceNotFound,
             .unsupportedStreamFormat,
             .ioProcCreationFailed,
             .startFailed:
            return false
        }
    }

    public static func map(
        status: OSStatus,
        during operation: AudioCaptureOperation
    ) -> AudioCaptureError {
        switch operation {
        case .tapCreation:
            return .tapCreationFailed(status)
        case .aggregateCreation:
            return .aggregateCreationFailed(status)
        case .ioProcCreation:
            return .ioProcCreationFailed(status)
        case .start:
            return .startFailed(status)
        case .write:
            return .fileWriteFailed("OSStatus \(status)")
        case .streamFormat:
            return .unsupportedStreamFormat(status)
        }
    }
}

public enum AudioCaptureWarning: Equatable, Sendable {
    case bluetoothInputMayDegradeQuality
    case selfExclusionUnavailable
    case framesDropped(UInt64)
    case systemAudioWasSilent
    case channelOrderAssumed
}
