import Foundation

nonisolated struct TimedTranscriptionWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?
}

nonisolated struct TimedTranscriptionSegment: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?
}

nonisolated struct DetailedTranscriptionResult: Equatable, Sendable {
    let text: String
    let words: [TimedTranscriptionWord]
    let segments: [TimedTranscriptionSegment]
    var costUSD: Double? = nil
}

nonisolated protocol DetailedTranscriptionServing: Sendable {
    func transcribeDetailed(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?,
        prompt: String?
    ) async throws -> DetailedTranscriptionResult
}
