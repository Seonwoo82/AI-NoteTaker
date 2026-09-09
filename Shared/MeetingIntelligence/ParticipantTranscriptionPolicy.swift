import Foundation

nonisolated enum ParticipantTranscriptionPolicy {
    static let fallbackModelID = "openai/whisper-large-v3"

    static func modelID(for selectedModelID: String) -> String {
        if selectedModelID.hasPrefix("openai/gpt") || selectedModelID == "microsoft/mai-transcribe-1.5" {
            return fallbackModelID
        }
        return selectedModelID
    }

    static func accepts(actual: String, requested: String) -> Bool {
        actual == requested || actual == modelID(for: requested) || actual == fallbackModelID
    }

    static func canRetryWithTimestamps(_ error: any Error, currentModel: String) -> Bool {
        guard currentModel != fallbackModelID, let error = error as? AIError else { return false }
        return error.reason == .httpStatus(400) || error.reason == .timestampsUnavailable
    }
}
