@preconcurrency import AVFAudio

protocol MicrophonePermissionRequesting: Sendable {
    func requestRecordPermission() async -> Bool
}

public enum AudioPermissions {
    public static func requestMicrophoneRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

struct AVAudioApplicationMicrophonePermissionRequester: MicrophonePermissionRequesting {
    func requestRecordPermission() async -> Bool {
        await AudioPermissions.requestMicrophoneRecordPermission()
    }
}
