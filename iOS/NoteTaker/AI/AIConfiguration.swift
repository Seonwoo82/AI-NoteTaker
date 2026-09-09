import Foundation
import Observation

@MainActor
@Observable
final class AIConfiguration {
    var settingsTab = "recording"
    private enum Keys {
        static let modelID = "ai.modelID"
        static let enhancementModelID = "ai.enhancementModelID"
        static let transcriptionModelID = "ai.transcriptionModelID"
        static let autoGenerate = "ai.autoGenerate"
        static let outputLanguage = "ai.outputLanguage"
        static let modelCatalog = "ai.modelCatalog"
    }

    private static let allowedLanguages = Set(["ko", "en", "source"])
    private static let preferredSummaryModelID = "google/gemini-2.5-flash"
    private static let preferredTranscriptionModelID = "openai/whisper-large-v3"

    @ObservationIgnored var client: any OpenRouterServing
    @ObservationIgnored var onCredentialsChanged: (() -> Void)?
    @ObservationIgnored private let keyStore: any APIKeyStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var credentialGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var applyingSharedPreferences = false
    @ObservationIgnored private var syncState: AIConfigurationSyncState
    @ObservationIgnored var onSyncStateChanged: (() -> Void)?
    private(set) var hasSyncedPreferences = false
    private(set) var otherDeviceHasAPIKey = false
    private(set) var isSharingAISettings = false

    var needsKeyForSyncedSettings: Bool { isSharingAISettings && otherDeviceHasAPIKey && !hasAPIKey }
    var shouldEnableAutomaticGenerationOnFirstKeySave: Bool { !hasAPIKey && !hasSyncedPreferences }
    var pendingPreferencesUpload: AISharedPreferences? { syncState.pending ? syncState.preferences : nil }

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID); if modelID != oldValue { preferencesChanged() } }
    }

    var enhancementModelID: String {
        didSet { defaults.set(enhancementModelID, forKey: Keys.enhancementModelID); if enhancementModelID != oldValue { preferencesChanged() } }
    }

    var transcriptionModelID: String {
        didSet { defaults.set(transcriptionModelID, forKey: Keys.transcriptionModelID); if transcriptionModelID != oldValue { preferencesChanged() } }
    }

    var autoGenerate: Bool {
        didSet {
            defaults.set(autoGenerate, forKey: Keys.autoGenerate)
            if autoGenerate != oldValue { preferencesChanged() }
        }
    }

    var outputLanguage: String {
        didSet {
            guard Self.allowedLanguages.contains(outputLanguage) else {
                outputLanguage = oldValue
                return
            }
            defaults.set(outputLanguage, forKey: Keys.outputLanguage)
            if outputLanguage != oldValue { preferencesChanged() }
        }
    }

    private(set) var models: [OpenRouterModel]
    private(set) var hasAPIKey: Bool
    private(set) var isLoadingModels: Bool
    private(set) var connectionMessage: String?
    private(set) var lastError: String?

    var isConfigured: Bool {
        guard hasAPIKey && !modelID.isEmpty && !transcriptionModelID.isEmpty else { return false }
        return models.isEmpty || (
            models.contains { $0.id == modelID && $0.supportsSummary }
                && models.contains { $0.id == transcriptionModelID && $0.supportsTranscription }
        )
    }

    var effectiveEnhancementModelID: String {
        enhancementModelID.isEmpty ? modelID : enhancementModelID
    }

    var isEnhancementConfigured: Bool {
        let modelID = effectiveEnhancementModelID
        guard hasAPIKey && !modelID.isEmpty else { return false }
        return models.isEmpty || models.contains { $0.id == modelID && $0.supportsSummary }
    }

    init(
        client: any OpenRouterServing,
        keyStore: any APIKeyStoring,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.keyStore = keyStore
        self.defaults = defaults
        syncState = defaults.data(forKey: "ai.sync.state.v1").flatMap {
            try? JSONDecoder().decode(AIConfigurationSyncState.self, from: $0)
        } ?? AIConfigurationSyncState()
        do { try syncState.preferences?.validate() }
        catch { syncState = AIConfigurationSyncState() }
        hasSyncedPreferences = syncState.hasSynced
        otherDeviceHasAPIKey = syncState.otherDeviceHasAPIKey
        modelID = defaults.string(forKey: Keys.modelID) ?? ""
        enhancementModelID = defaults.string(forKey: Keys.enhancementModelID) ?? ""
        transcriptionModelID = defaults.string(forKey: Keys.transcriptionModelID) ?? ""
        let savedLanguage = defaults.string(forKey: Keys.outputLanguage) ?? "ko"
        outputLanguage = Self.allowedLanguages.contains(savedLanguage) ? savedLanguage : "ko"
        let storedKey = (try? keyStore.read()) ?? nil
        let hasStoredKey = storedKey?.isEmpty == false
        hasAPIKey = hasStoredKey
        let savedAutoGenerate = (defaults.object(forKey: Keys.autoGenerate) as? Bool) ?? false
        autoGenerate = savedAutoGenerate
        models = defaults.data(forKey: Keys.modelCatalog).flatMap {
            try? JSONDecoder().decode([OpenRouterModel].self, from: $0)
        } ?? []
        isLoadingModels = false
        connectionMessage = nil
        lastError = nil
    }

    func saveKey(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIError(message: "OpenRouter API 키를 입력해 주세요.")
        }
        guard !rawKey.contains("\n"), !rawKey.contains("\r"), !key.contains(" "), !key.contains("\t") else {
            throw AIError(message: "OpenRouter API 키에 사용할 수 없는 공백이 있어요. 키를 다시 확인해 주세요.")
        }
        try keyStore.save(key)
        credentialGeneration += 1
        hasAPIKey = true
        connectionMessage = nil
        lastError = nil
        onCredentialsChanged?()
        onSyncStateChanged?()
    }

    func saveKeyFromSettings(_ rawKey: String) throws {
        let enableAutomaticGeneration = shouldEnableAutomaticGenerationOnFirstKeySave
        try saveKey(rawKey)
        if enableAutomaticGeneration { autoGenerate = true }
    }

    func removeKey() throws {
        try keyStore.delete()
        credentialGeneration += 1
        hasAPIKey = false
        connectionMessage = nil
        lastError = nil
        onCredentialsChanged?()
        onSyncStateChanged?()
    }

    func apiKey() throws -> String {
        guard let key = try keyStore.read(), !key.isEmpty else {
            throw AIError(message: "OpenRouter API 키가 저장되어 있지 않아요.")
        }
        return key
    }

    func refreshModels() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoadingModels = true
        defer {
            if generation == refreshGeneration {
                isLoadingModels = false
            }
        }

        do {
            let fetchedModels = try await client.models()
            guard generation == refreshGeneration else { return }
            let mergedModels = mergeUnavailableSelections(into: fetchedModels)
            models = mergedModels
            if let catalog = try? JSONEncoder().encode(fetchedModels) {
                defaults.set(catalog, forKey: Keys.modelCatalog)
            }
            chooseModelIDs(from: fetchedModels)
            lastError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            lastError = sanitizedMessage(from: error)
        }
    }

    func testConnection() async {
        let generation = credentialGeneration
        do {
            let key = try apiKey()
            try await client.validateKey(key)
            guard generation == credentialGeneration else { return }
            connectionMessage = "연결에 성공했어요."
            lastError = nil
        } catch {
            guard generation == credentialGeneration else { return }
            connectionMessage = nil
            lastError = sanitizedMessage(from: error)
        }
    }

    private func mergeUnavailableSelections(into fetchedModels: [OpenRouterModel]) -> [OpenRouterModel] {
        var merged = fetchedModels
        let fetchedIDs = Set(fetchedModels.map(\.id))
        if !modelID.isEmpty, !fetchedIDs.contains(modelID) {
            merged.append(OpenRouterModel(
                id: modelID,
                name: "\(modelID) (사용할 수 없음)",
                contextLength: 0,
                inputModalities: [],
                outputModalities: []
            ))
        }
        if !enhancementModelID.isEmpty, !fetchedIDs.contains(enhancementModelID) {
            merged.append(OpenRouterModel(
                id: enhancementModelID,
                name: "\(enhancementModelID) (사용할 수 없음)",
                contextLength: 0,
                inputModalities: [],
                outputModalities: []
            ))
        }
        if !transcriptionModelID.isEmpty, !fetchedIDs.contains(transcriptionModelID) {
            merged.append(OpenRouterModel(
                id: transcriptionModelID,
                name: "\(transcriptionModelID) (사용할 수 없음)",
                contextLength: 0,
                inputModalities: [],
                outputModalities: []
            ))
        }
        return merged
    }

    private func chooseModelIDs(from models: [OpenRouterModel]) {
        let wasApplying = applyingSharedPreferences
        applyingSharedPreferences = true
        defer { applyingSharedPreferences = wasApplying }
        let summaryCandidates = models.filter(\.supportsSummary)
        let transcriptionCandidates = models.filter(\.supportsTranscription)

        if modelID.isEmpty && !hasSyncedPreferences {
            if let preferred = summaryCandidates.first(where: { $0.id == Self.preferredSummaryModelID }) {
                modelID = preferred.id
            } else if let fallback = summaryCandidates.first {
                modelID = fallback.id
            }
        }

        if transcriptionModelID.isEmpty && !hasSyncedPreferences {
            if let preferred = transcriptionCandidates.first(where: { $0.id == Self.preferredTranscriptionModelID }) {
                transcriptionModelID = preferred.id
            } else if let fallback = transcriptionCandidates.first {
                transcriptionModelID = fallback.id
            }
        }
    }

    func setSyncContext(endpoint: String, enabled: Bool) {
        let workspace = try? SyncConfiguration(endpoint: endpoint, token: "context-only").endpoint.absoluteString
        isSharingAISettings = enabled && workspace != nil
        guard let workspace else { return }
        if let previous = syncState.workspace, previous != workspace {
            syncState = AIConfigurationSyncState()
            hasSyncedPreferences = false
            otherDeviceHasAPIKey = false
        }
        syncState.workspace = workspace
        persistSyncState()
    }

    func preparePreferencesUpload(serverPreferences: AISharedPreferences?) {
        if let serverPreferences {
            acceptSharedPreferences(serverPreferences)
        } else if syncState.preferences != nil {
            syncState.pending = true
            persistSyncState()
        } else if !modelID.isEmpty || !enhancementModelID.isEmpty || !transcriptionModelID.isEmpty || autoGenerate || outputLanguage != "ko" {
            preferencesChanged(notify: false)
        }
    }

    func acceptSharedPreferences(_ preferences: AISharedPreferences) {
        if let local = syncState.preferences, local.wins(over: preferences) {
            syncState.pending = true
            persistSyncState()
            return
        }
        applyingSharedPreferences = true
        modelID = preferences.modelID
        let acceptedEnhancementModelID = preferences.enhancementModelID ?? enhancementModelID
        enhancementModelID = acceptedEnhancementModelID
        transcriptionModelID = preferences.transcriptionModelID
        outputLanguage = preferences.outputLanguage
        autoGenerate = preferences.autoGenerate
        applyingSharedPreferences = false
        syncState.preferences = AISharedPreferences(modelID: preferences.modelID, enhancementModelID: preferences.enhancementModelID ?? acceptedEnhancementModelID,
            transcriptionModelID: preferences.transcriptionModelID, outputLanguage: preferences.outputLanguage, autoGenerate: preferences.autoGenerate,
            modifiedAt: preferences.modifiedAt, mutationID: preferences.mutationID)
        syncState.pending = false
        syncState.hasSynced = true
        hasSyncedPreferences = true
        persistSyncState()
    }

    func setOtherDeviceKeyPresence(_ present: Bool) {
        otherDeviceHasAPIKey = present
        syncState.otherDeviceHasAPIKey = present
        persistSyncState()
    }

    func keyPresenceForSync() -> Bool? {
        do {
            let present = try keyStore.read()?.isEmpty == false
            if hasAPIKey != present {
                hasAPIKey = present
                onCredentialsChanged?()
            }
            return present
        } catch {
            // A locked/unavailable Keychain must not erase another device's known status.
            return nil
        }
    }

    private func preferencesChanged(notify: Bool = true) {
        guard !applyingSharedPreferences else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let modified = max(now, min((syncState.preferences?.modifiedAt ?? 0) + 1, 9_007_199_254_740_991))
        syncState.preferences = AISharedPreferences(modelID: modelID, enhancementModelID: enhancementModelID,
            transcriptionModelID: transcriptionModelID, outputLanguage: outputLanguage, autoGenerate: autoGenerate, modifiedAt: modified, mutationID: UUID())
        syncState.pending = true
        persistSyncState()
        if notify { onSyncStateChanged?() }
    }

    private func persistSyncState() {
        if let data = try? JSONEncoder().encode(syncState) { defaults.set(data, forKey: "ai.sync.state.v1") }
    }

    private func sanitizedMessage(from error: any Error) -> String {
        if let aiError = error as? AIError {
            return aiError.message
        }
        return "AI 설정 작업에 실패했어요. 잠시 후 다시 시도해 주세요."
    }
}

private struct AIConfigurationSyncState: Codable {
    var workspace: String?
    var preferences: AISharedPreferences?
    var pending = false
    var hasSynced = false
    var otherDeviceHasAPIKey = false
}
