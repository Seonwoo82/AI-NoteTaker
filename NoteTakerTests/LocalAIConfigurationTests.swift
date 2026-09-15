import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Local AI configuration")
struct LocalAIConfigurationTests {
    @Test("local mode is configured by readiness without a stored API key")
    func localModeUsesReadinessInsteadOfAPIKey() throws {
        let defaults = try isolatedLocalAIDefaults()
        let configuration = AIConfiguration(
            client: LocalAIStubClient(),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults,
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") },
            localPreparation: { _ in LocalAIStatus(isAvailable: true, message: "prepared") }
        )
        configuration.modelID = "fixture/cloud-summary"
        configuration.enhancementModelID = "fixture/cloud-enhancement"
        configuration.transcriptionModelID = "fixture/cloud-transcription"
        configuration.setOtherDeviceKeyPresence(true)
        configuration.setSyncContext(endpoint: "https://sync.example.test", enabled: true)

        configuration.processingMode = .onDevice

        #expect(configuration.usesLocalAI)
        #expect(configuration.localSpeechLocaleIdentifier == "ko-KR")
        #expect(configuration.localStatus == LocalAIStatus(isAvailable: true, message: "ready"))
        #expect(configuration.isConfigured)
        #expect(!configuration.hasAPIKey)
        #expect(!configuration.needsKeyForSyncedSettings)
        #expect(configuration.effectiveModelID == LocalAIModel.summaryID)
        #expect(configuration.effectiveTranscriptionModelID == LocalAIModel.transcriptionID(localeIdentifier: "ko-KR"))
        #expect(configuration.effectiveSummaryModel == LocalAIModel.summaryDescriptor)
        #expect(try configuration.generationAPIKey() == "")
        #expect(!configuration.isEnhancementConfigured)
        #expect(!configuration.isTranscriptCleanupConfigured)
        #expect(configuration.modelID == "fixture/cloud-summary")
        #expect(configuration.enhancementModelID == "fixture/cloud-enhancement")
        #expect(configuration.transcriptionModelID == "fixture/cloud-transcription")
    }

    @Test("local mode refreshModels does not call the cloud catalog")
    func localModeRefreshModelsSkipsCloudCatalog() async throws {
        let defaults = try isolatedLocalAIDefaults()
        let client = CountingLocalAIStubClient()
        let configuration = AIConfiguration(
            client: client,
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults,
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") },
            localPreparation: { _ in LocalAIStatus(isAvailable: true, message: "ready") }
        )
        configuration.processingMode = .onDevice

        await configuration.refreshModels()

        #expect(await client.modelsCallCount() == 0)
        #expect(!configuration.isLoadingModels)
        #expect(configuration.lastError == nil)
    }


    @Test("stale local preparation cannot overwrite the current locale status")
    func staleLocalPreparationDoesNotOverwriteCurrentLocale() async throws {
        let defaults = try isolatedLocalAIDefaults()
        var capturedContinuation: CheckedContinuation<LocalAIStatus, Never>?
        let configuration = AIConfiguration(
            client: LocalAIStubClient(),
            keyStore: InMemoryAPIKeyStore(),
            defaults: defaults,
            localStatusProvider: { locale in LocalAIStatus(isAvailable: locale == "en-US", message: "current \(locale)") },
            localPreparation: { locale in
                if locale == "ko-KR" {
                    return await withCheckedContinuation { continuation in
                        capturedContinuation = continuation
                    }
                }
                return LocalAIStatus(isAvailable: true, message: "prepared \(locale)")
            }
        )
        configuration.processingMode = .onDevice

        let preparation = Task { await configuration.prepareLocalAI() }
        while capturedContinuation == nil {
            await Task.yield()
        }

        configuration.localSpeechLocaleIdentifier = "en-US"
        capturedContinuation?.resume(returning: LocalAIStatus(isAvailable: true, message: "stale ko-KR"))
        await preparation.value

        #expect(configuration.localStatus == LocalAIStatus(isAvailable: true, message: "current en-US"))
    }


    @Test("mode and local speech locale are per-device and trigger cancellation")
    func modeAndLocaleAreLocalOnly() throws {
        let defaults = try isolatedLocalAIDefaults()
        let configuration = AIConfiguration(
            client: LocalAIStubClient(),
            keyStore: InMemoryAPIKeyStore("fixture-key"),
            defaults: defaults,
            localStatusProvider: { locale in LocalAIStatus(isAvailable: locale == "en-US", message: locale) },
            localPreparation: { locale in LocalAIStatus(isAvailable: locale == "en-US", message: locale) }
        )
        var credentialChanges = 0
        configuration.onCredentialsChanged = { credentialChanges += 1 }
        configuration.modelID = "fixture/cloud-summary"
        configuration.transcriptionModelID = "fixture/cloud-transcription"

        configuration.processingMode = .onDevice
        configuration.localSpeechLocaleIdentifier = "en-US"

        #expect(credentialChanges == 2)
        #expect(configuration.localStatus == LocalAIStatus(isAvailable: true, message: "en-US"))
        #expect(defaults.string(forKey: "ai.processingMode") == "onDevice")
        #expect(defaults.string(forKey: "ai.localSpeechLocaleIdentifier") == "en-US")
        let upload = try #require(configuration.pendingPreferencesUpload)
        #expect(upload.modelID == "fixture/cloud-summary")
        #expect(upload.transcriptionModelID == "fixture/cloud-transcription")
        let json = String(decoding: try JSONEncoder().encode(upload), as: UTF8.self)
        #expect(!json.contains("onDevice"))
        #expect(!json.contains("en-US"))

        let reloaded = AIConfiguration(
            client: LocalAIStubClient(),
            keyStore: InMemoryAPIKeyStore("fixture-key"),
            defaults: defaults,
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") },
            localPreparation: { _ in LocalAIStatus(isAvailable: true, message: "ready") }
        )
        #expect(reloaded.processingMode == .onDevice)
        #expect(reloaded.localSpeechLocaleIdentifier == "en-US")
        #expect(reloaded.modelID == "fixture/cloud-summary")
        #expect(reloaded.transcriptionModelID == "fixture/cloud-transcription")
    }
}

nonisolated private struct LocalAIStubClient: OpenRouterServing {
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        AITextResponse(text: "")
    }
}

private actor CountingLocalAIStubClient: OpenRouterServing {
    private var modelCalls = 0

    func modelsCallCount() -> Int { modelCalls }

    func models() async throws -> [OpenRouterModel] {
        modelCalls += 1
        return []
    }

    func validateKey(_ apiKey: String) async throws {}

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        AITextResponse(text: "")
    }
}

private func isolatedLocalAIDefaults() throws -> UserDefaults {
    let suiteName = "NoteTakerLocalAIConfigurationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
