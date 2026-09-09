import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite
struct AIConfigurationTests {
    @Test("requested automatic generation survives missing or removed device credentials")
    func automaticGenerationPreferenceIsIndependentOfCredentials() throws {
        let defaults = try isolatedDefaults()
        defaults.set(true, forKey: "ai.autoGenerate")
        let keyStore = InMemoryAPIKeyStore()
        let configuration = AIConfiguration(client: StubOpenRouterClient(models: []), keyStore: keyStore, defaults: defaults)
        #expect(configuration.autoGenerate)
        #expect(!configuration.isConfigured)
        try configuration.saveKey("synthetic-key")
        configuration.autoGenerate = true
        try configuration.removeKey()
        #expect(configuration.autoGenerate)
        #expect(!configuration.isConfigured)
    }

    @Test("defaults require a stored key before auto generation is enabled")
    func defaultsRequireStoredKeyBeforeAutoGeneration() throws {
        let defaults = try isolatedDefaults()
        let configuration = AIConfiguration(
            client: StubOpenRouterClient(models: []),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults
        )

        #expect(configuration.outputLanguage == "ko")
        #expect(configuration.autoGenerate == false)
        #expect(configuration.transcriptCleanupEnabled == true)
        #expect(defaults.object(forKey: "ai.transcriptCleanupEnabled") as? Bool == true)
        #expect(configuration.pendingPreferencesUpload == nil)
        #expect(configuration.hasAPIKey == false)
        #expect(configuration.isConfigured == false)
    }

    @Test("explicit transcript cleanup opt out persists across configuration reloads")
    func transcriptCleanupOptOutPersists() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: "ai.transcriptCleanupEnabled")
        let configuration = AIConfiguration(
            client: StubOpenRouterClient(models: []),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults
        )

        #expect(configuration.transcriptCleanupEnabled == false)
        configuration.transcriptCleanupEnabled = true
        let reloaded = AIConfiguration(
            client: StubOpenRouterClient(models: []),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults
        )
        #expect(reloaded.transcriptCleanupEnabled == true)
    }

    @Test("transcript cleanup readiness requires only a valid minutes model and local key")
    func transcriptCleanupReadinessUsesMinutesModelAndKey() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("fixture/summary", forKey: "ai.modelID")
        let models = [
            OpenRouterModel(id: "fixture/summary", name: "Summary", contextLength: 9000, inputModalities: ["text"], outputModalities: ["text"])
        ]
        let configuration = AIConfiguration(
            client: StubOpenRouterClient(models: models),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults
        )

        #expect(configuration.isTranscriptCleanupConfigured == false)
        try configuration.saveKey("fixture-key")
        #expect(configuration.isTranscriptCleanupConfigured == true)
        await configuration.refreshModels()
        configuration.modelID = "fixture/missing-summary"
        #expect(configuration.isTranscriptCleanupConfigured == false)
    }

    @Test("saveKey trims outer whitespace, rejects CRLF, avoids defaults, and preserves explicit opt out")
    func saveKeyValidatesAndPreservesOptOut() throws {
        let defaults = try isolatedDefaults()
        let keyStore = InMemoryAPIKeyStore()
        let configuration = AIConfiguration(client: StubOpenRouterClient(models: []), keyStore: keyStore, defaults: defaults)
        var callbackCount = 0
        configuration.onCredentialsChanged = { callbackCount += 1 }

        try configuration.saveKey("  sk-or-secret  ")
        configuration.autoGenerate = false
        try configuration.saveKey("sk-or-replacement")

        #expect(try keyStore.read() == "sk-or-replacement")
        #expect(configuration.hasAPIKey)
        #expect(configuration.autoGenerate == false)
        #expect(callbackCount == 2)
        #expect(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("sk-or") } == false)
        #expect(throws: AIError.self) {
            try configuration.saveKey("sk-or-one\nInjected: header")
        }
    }

    @Test("preferences use AI fixture keys and no key is stored in defaults")
    func preferencesUseFixtureKeys() throws {
        let defaults = try isolatedDefaults()
        let configuration = AIConfiguration(
            client: StubOpenRouterClient(models: []),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults
        )

        configuration.modelID = "fixture/summary"
        configuration.transcriptionModelID = "fixture/transcription"
        configuration.outputLanguage = "en"

        let reloaded = AIConfiguration(client: StubOpenRouterClient(models: []), keyStore: InMemoryAPIKeyStore(), defaults: defaults)
        #expect(reloaded.modelID == "fixture/summary")
        #expect(reloaded.transcriptionModelID == "fixture/transcription")
        #expect(reloaded.outputLanguage == "en")
        #expect(defaults.string(forKey: "ai.modelID") == "fixture/summary")
        #expect(defaults.string(forKey: "ai.transcriptionModelID") == "fixture/transcription")
        #expect(throws: AIError.self) {
            _ = try reloaded.apiKey()
        }
    }

    @Test("enhancement model can follow the minutes model or use its own text model")
    func enhancementModelCanFollowOrOverrideMinutesModel() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("fixture/summary", forKey: "ai.modelID")
        let models = [
            OpenRouterModel(id: "fixture/summary", name: "Summary", contextLength: 9000, inputModalities: ["text"], outputModalities: ["text"]),
            OpenRouterModel(id: "fixture/enhancement", name: "Enhancement", contextLength: 9000, inputModalities: ["text"], outputModalities: ["text"]),
            OpenRouterModel(id: "fixture/transcription", name: "Transcription", contextLength: 0, inputModalities: ["audio"], outputModalities: ["transcription"])
        ]
        let configuration = AIConfiguration(client: StubOpenRouterClient(models: models), keyStore: InMemoryAPIKeyStore(), defaults: defaults)

        #expect(configuration.enhancementModelID == "")
        #expect(configuration.effectiveEnhancementModelID == "fixture/summary")
        #expect(!configuration.isEnhancementConfigured)

        try configuration.saveKey("fixture-key")
        await configuration.refreshModels()
        #expect(configuration.isEnhancementConfigured)

        configuration.enhancementModelID = "fixture/enhancement"
        #expect(configuration.effectiveEnhancementModelID == "fixture/enhancement")
        #expect(configuration.isEnhancementConfigured)

        let reloaded = AIConfiguration(client: StubOpenRouterClient(models: models), keyStore: InMemoryAPIKeyStore("fixture-key"), defaults: defaults)
        #expect(reloaded.enhancementModelID == "fixture/enhancement")
        #expect(reloaded.effectiveEnhancementModelID == "fixture/enhancement")
    }

    @Test("refreshModels chooses preferred valid defaults while preserving unavailable saved IDs")
    func refreshModelsChoosesPreferredDefaults() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("previous-summary", forKey: "ai.modelID")
        defaults.set("previous-enhancement", forKey: "ai.enhancementModelID")
        defaults.set("previous-stt", forKey: "ai.transcriptionModelID")
        let models = [
            OpenRouterModel(id: "other/text", name: "Other", contextLength: 9000, inputModalities: ["text"], outputModalities: ["text"]),
            OpenRouterModel(id: "google/gemini-2.5-flash", name: "Gemini", contextLength: 1_000_000, inputModalities: ["text"], outputModalities: ["text"]),
            OpenRouterModel(id: "openai/whisper-large-v3", name: "Whisper", contextLength: 0, inputModalities: ["audio"], outputModalities: ["transcription"])
        ]
        let configuration = AIConfiguration(client: StubOpenRouterClient(models: models), keyStore: InMemoryAPIKeyStore(), defaults: defaults)

        await configuration.refreshModels()

        #expect(configuration.modelID == "previous-summary")
        #expect(configuration.enhancementModelID == "previous-enhancement")
        #expect(configuration.transcriptionModelID == "previous-stt")
        #expect(configuration.models.map(\.id).contains("previous-summary"))
        #expect(configuration.models.map(\.id).contains("previous-enhancement"))
        #expect(configuration.models.map(\.id).contains("previous-stt"))
        try configuration.saveKey("fixture-key")
        #expect(!configuration.isConfigured)
        configuration.modelID = ""
        configuration.transcriptionModelID = ""
        await configuration.refreshModels()
        #expect(configuration.modelID == "google/gemini-2.5-flash")
        #expect(configuration.transcriptionModelID == "openai/whisper-large-v3")
        #expect(configuration.isConfigured)
    }

    @Test("testConnection validates latest stored key and ignores stale concurrent results")
    func testConnectionIgnoresStaleResults() async throws {
        let client = DelayedValidationClient()
        let keyStore = InMemoryAPIKeyStore()
        let configuration = AIConfiguration(client: client, keyStore: keyStore, defaults: try isolatedDefaults())
        try configuration.saveKey("sk-or-first")

        async let first: Void = configuration.testConnection()
        await client.waitForValidationCount(1)
        try configuration.saveKey("sk-or-second")
        await configuration.testConnection()
        client.finishValidation(for: "sk-or-first", error: AIError(message: "stale failure"))
        await first

        #expect(await client.validatedKeys == ["sk-or-first", "sk-or-second"])
        #expect(configuration.connectionMessage == "연결에 성공했어요.")
        #expect(configuration.lastError == nil)
    }

    @Test("removeKey disables generated notes and invokes credential callback")
    func removeKeyDisablesGeneratedNotes() throws {
        let keyStore = InMemoryAPIKeyStore("sk-or-secret")
        let configuration = AIConfiguration(client: StubOpenRouterClient(models: []), keyStore: keyStore, defaults: try isolatedDefaults())
        var callbackCount = 0
        configuration.onCredentialsChanged = { callbackCount += 1 }

        try configuration.removeKey()

        #expect(try keyStore.read() == nil)
        #expect(configuration.hasAPIKey == false)
        #expect(configuration.autoGenerate == false)
        #expect(callbackCount == 1)
    }
}

nonisolated private struct StubOpenRouterClient: OpenRouterServing {
    var models: [OpenRouterModel] = []
    var error: (any Error)?

    func models() async throws -> [OpenRouterModel] {
        if let error { throw error }
        return models
    }

    func validateKey(_ apiKey: String) async throws {
        if let error { throw error }
    }

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        AITextResponse(text: "")
    }
}

private actor DelayedValidationClient: OpenRouterServing {
    private var continuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private var countContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var validatedKeys: [String] = []

    func models() async throws -> [OpenRouterModel] { [] }

    func validateKey(_ apiKey: String) async throws {
        validatedKeys.append(apiKey)
        countContinuations.forEach { $0.resume() }
        countContinuations.removeAll()
        if apiKey == "sk-or-second" { return }
        try await withCheckedThrowingContinuation { continuation in
            continuations[apiKey] = continuation
        }
    }

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func waitForValidationCount(_ expected: Int) async {
        if validatedKeys.count >= expected { return }
        await withCheckedContinuation { continuation in
            if validatedKeys.count >= expected {
                continuation.resume()
            } else {
                countContinuations.append(continuation)
            }
        }
    }

    nonisolated func finishValidation(for key: String, error: (any Error)? = nil) {
        Task {
            await finishValidationIsolated(for: key, error: error)
        }
    }

    private func finishValidationIsolated(for key: String, error: (any Error)?) {
        let continuation = continuations.removeValue(forKey: key)
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

private func isolatedDefaults() throws -> UserDefaults {
    let suiteName = "NoteTakerAIConfigurationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
