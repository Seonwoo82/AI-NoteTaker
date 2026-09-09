import Foundation

nonisolated struct MeetingNotesEnhancement: Codable, Equatable, Sendable {
    let modelID: String
    let instructions: String
}

nonisolated struct MeetingNotesEnhancementPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let original: MeetingNotesDocument
    let markdown: String
    let modelID: String
    let instructions: String
    let costUSD: Double?
}

nonisolated extension MeetingNotesDocument {
    func participantTranscript(resolvingWith resolved: MeetingTranscript?) -> MeetingTranscript? {
        if let resolved, resolved.recordingID == recordingID, resolved.audioVersion == audioVersion,
           resolved.transcriptionModelID == transcriptionModelID {
            return resolved
        }
        return speakerTranscript
    }
}
