import Foundation
import Testing
import AudioPipeline

@Test("capture permission errors expose exact System Settings deep links")
func capturePermissionErrorsExposeSettingsDeepLinks() {
    #expect(
        AudioCaptureError.microphonePermissionDenied.settingsURL
            == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    )
    #expect(
        AudioCaptureError.systemAudioPermissionDenied.settingsURL
            == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    )
    #expect(AudioCaptureError.tapCreationFailed(-50).settingsURL == nil)
}

@Test("capture errors keep partial files only after recording output may exist")
func captureErrorsKeepPartialFilesOnlyAfterOutputMayExist() {
    let keepsPartialFile: [AudioCaptureError] = [
        .outputAlreadyExists("/tmp/existing.m4a"),
        .fileWriteFailed("OSStatus -50"),
        .diskSpaceLow,
        .deviceDisconnected,
        .ioStoppedAbnormally,
        .streamFormatChanged
    ]

    for error in keepsPartialFile {
        #expect(error.keepsPartialFile, "\(error) should keep partial file")
    }

    let discardsPartialFile: [AudioCaptureError] = [
        .unsupportedCaptureMode(.systemOnly),
        .microphonePermissionDenied,
        .systemAudioPermissionDenied,
        .tapCreationFailed(-50),
        .aggregateCreationFailed(-50),
        .deviceNotFound(uid: nil),
        .deviceNotFound(uid: "BuiltInMicrophoneDevice"),
        .unsupportedStreamFormat(nil),
        .unsupportedStreamFormat(-50),
        .ioProcCreationFailed(-50),
        .startFailed(-50)
    ]

    for error in discardsPartialFile {
        #expect(!error.keepsPartialFile, "\(error) should not keep partial file")
    }
}

@Test("OSStatus mapping preserves operation-specific status details")
func osStatusMappingPreservesOperationSpecificStatusDetails() {
    let status: OSStatus = -50
    let mappings: [(AudioCaptureOperation, AudioCaptureError)] = [
        (.tapCreation, .tapCreationFailed(status)),
        (.aggregateCreation, .aggregateCreationFailed(status)),
        (.ioProcCreation, .ioProcCreationFailed(status)),
        (.start, .startFailed(status)),
        (.write, .fileWriteFailed("OSStatus -50")),
        (.streamFormat, .unsupportedStreamFormat(status))
    ]

    for (operation, expectedError) in mappings {
        #expect(AudioCaptureError.map(status: status, during: operation) == expectedError)
    }
}

@Test("capture warning associated values remain distinguishable")
func captureWarningAssociatedValuesRemainDistinguishable() {
    #expect(AudioCaptureWarning.framesDropped(1) != .framesDropped(2))
    #expect(AudioCaptureWarning.bluetoothInputMayDegradeQuality != .selfExclusionUnavailable)
    #expect(AudioCaptureWarning.systemAudioWasSilent != .channelOrderAssumed)
}
