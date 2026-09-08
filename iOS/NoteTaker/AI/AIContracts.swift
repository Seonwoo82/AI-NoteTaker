import Foundation

nonisolated struct OpenRouterModel: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let contextLength: Int
    let inputModalities: [String]
    let outputModalities: [String]
    var promptPrice: String? = nil
    var completionPrice: String? = nil

    var supportsSummary: Bool {
        inputModalities.contains("text") && outputModalities.contains("text") && contextLength >= 8_192
    }
    var supportsTranscription: Bool { outputModalities.contains("transcription") }

    /// GLM 5.3 always reasons; disabling thinking is not supported by the provider.
    static func requiresReasoningBudget(for modelID: String) -> Bool {
        modelID == "z-ai/glm-5.3"
            || modelID.hasPrefix("z-ai/glm-5.3-")
            || modelID.hasPrefix("z-ai/glm-5.3:")
    }
}

nonisolated struct AITextResponse: Sendable {
    let text: String
    var costUSD: Double? = nil
}

nonisolated protocol OpenRouterServing: Sendable {
    func models() async throws -> [OpenRouterModel]
    func validateKey(_ apiKey: String) async throws
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse
}

@MainActor
protocol APIKeyStoring {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

nonisolated struct AudioChunk: Sendable {
    let data: Data
    let format: String
    let startTime: TimeInterval
    let duration: TimeInterval
}

nonisolated protocol MeetingAudioChunking: Sendable {
    func chunkCount(for url: URL) async throws -> Int
    func chunk(for url: URL, index: Int) async throws -> AudioChunk
}

nonisolated struct MeetingNotesDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let recordingID: UUID
    let audioVersion: Int
    let generatedAt: Date
    let modelID: String
    let transcriptionModelID: String
    let markdown: String
    let transcript: String
    var costUSD: Double? = nil
}

nonisolated enum MeetingNotesProgress: Equatable, Sendable {
    case idle, queued
    case transcribing(completed: Int, total: Int)
    case summarizing(completed: Int, total: Int)
    case completed, cancelled
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .queued, .transcribing, .summarizing: true
        default: false
        }
    }
}

nonisolated struct AIError: LocalizedError, Sendable, Equatable {
    let message: String
    var errorDescription: String? { message }
}
