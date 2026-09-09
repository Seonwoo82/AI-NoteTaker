import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("AI settings sync")
struct AISettingsSyncTests {
    let mac = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let phone = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let workspace = "https://sync.example.test"

    @Test("a new device receives preferences and missing-key guidance without receiving credentials")
    func sharesPreferencesButNotKeys() async throws {
        let server = SettingsServer()
        let first = fixture(key: "sk-or-private-fixture", configured: true)
        first.config.autoGenerate = true
        first.config.enhancementModelID = "fixture/enhancement"
        let firstSync = AISettingsSynchronizer(configuration: first.config, deviceID: mac)
        try await firstSync.synchronize(transport: server, workspace: workspace)
        let second = fixture()
        let secondSync = AISettingsSynchronizer(configuration: second.config, deviceID: phone)
        try await secondSync.synchronize(transport: server, workspace: workspace)
        #expect(second.config.modelID == "fixture/summary")
        #expect(second.config.enhancementModelID == "fixture/enhancement")
        #expect(second.config.effectiveEnhancementModelID == "fixture/enhancement")
        #expect(second.config.transcriptionModelID == "fixture/transcription")
        #expect(second.config.outputLanguage == "en")
        #expect(second.config.autoGenerate)
        #expect(!second.config.hasAPIKey && !second.config.isConfigured)
        #expect(second.config.needsKeyForSyncedSettings)
        #expect(try second.keyStore.read() == nil)
        #expect(server.uploads.last?.preferences == nil)
        for upload in server.uploads {
            let json = String(decoding: try JSONEncoder().encode(upload), as: UTF8.self)
            #expect(!json.contains("sk-or-private-fixture"))
        }
        #expect(first.config.needsKeyForSyncedSettings == false)
    }

    @Test("old synced preferences without an enhancement model keep following the minutes model")
    func oldPreferencesFollowMinutesModel() throws {
        let json = """
        {"schemaVersion":1,"modelID":"fixture/summary","transcriptionModelID":"fixture/transcription","outputLanguage":"en","autoGenerate":true,"modifiedAt":1,"mutationID":"\(mac.uuidString)"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AISharedPreferences.self, from: data)
        let second = fixture()

        second.config.acceptSharedPreferences(decoded)

        #expect(second.config.enhancementModelID == "")
        #expect(second.config.effectiveEnhancementModelID == "fixture/summary")
    }

    @Test("new clients upload an explicit empty enhancement model when following minutes again")
    func uploadsExplicitEmptyEnhancementModelWhenResetToFollow() async throws {
        let server = SettingsServer()
        let first = fixture(configured: true)
        first.config.enhancementModelID = "fixture/enhancement"
        try await AISettingsSynchronizer(configuration: first.config, deviceID: mac).synchronize(transport: server, workspace: workspace)

        first.config.enhancementModelID = ""
        try await AISettingsSynchronizer(configuration: first.config, deviceID: mac).synchronize(transport: server, workspace: workspace)

        #expect(server.preferences?.enhancementModelID == "")
        #expect(first.config.enhancementModelID == "")
        #expect(first.config.effectiveEnhancementModelID == "fixture/summary")
    }

    @Test("legacy synced preferences without enhancement model preserve an existing local enhancement choice")
    func legacyPreferencesPreserveExistingEnhancementModel() throws {
        let first = fixture(configured: true)
        first.config.enhancementModelID = "fixture/enhancement"
        let json = """
        {"schemaVersion":1,"modelID":"fixture/summary","transcriptionModelID":"fixture/transcription","outputLanguage":"source","autoGenerate":true,"modifiedAt":9007199254740991,"mutationID":"\(phone.uuidString)"}
        """
        let decoded = try JSONDecoder().decode(AISharedPreferences.self, from: Data(json.utf8))

        first.config.acceptSharedPreferences(decoded)

        #expect(first.config.enhancementModelID == "fixture/enhancement")
        #expect(first.config.outputLanguage == "source")
    }

    @Test("entering a local key preserves a synced disabled automatic-generation preference")
    func enteringKeyPreservesSharedPreference() async throws {
        let server = SettingsServer()
        let first = fixture(key: "private-fixture", configured: true)
        try await AISettingsSynchronizer(configuration: first.config, deviceID: mac).synchronize(transport: server, workspace: workspace)
        let second = fixture()
        try await AISettingsSynchronizer(configuration: second.config, deviceID: phone).synchronize(transport: server, workspace: workspace)
        #expect(!second.config.shouldEnableAutomaticGenerationOnFirstKeySave)
        try second.config.saveKeyFromSettings("another-private-fixture")
        #expect(!second.config.autoGenerate)
        #expect(second.config.hasAPIKey && !second.config.needsKeyForSyncedSettings)
    }

    @Test("removing a key clears the remote notice without disabling the shared generation preference")
    func removalOnlyChangesDevicePresence() async throws {
        let server = SettingsServer()
        let first = fixture(key: "private-fixture", configured: true)
        first.config.autoGenerate = true
        let firstSync = AISettingsSynchronizer(configuration: first.config, deviceID: mac)
        try await firstSync.synchronize(transport: server, workspace: workspace)
        try first.config.removeKey()
        try await firstSync.synchronize(transport: server, workspace: workspace)
        #expect(first.config.autoGenerate)
        let second = fixture()
        try await AISettingsSynchronizer(configuration: second.config, deviceID: phone).synchronize(transport: server, workspace: workspace)
        #expect(second.config.autoGenerate)
        #expect(!second.config.needsKeyForSyncedSettings)
    }

    @Test("offline preference edits survive a restart and retry")
    func retriesPersistedEdits() async throws {
        let server = SettingsServer()
        let first = fixture()
        first.config.outputLanguage = "source"
        first.config.enhancementModelID = "fixture/enhancement"
        server.fails = true
        await #expect(throws: SyncError.self) {
            try await AISettingsSynchronizer(configuration: first.config, deviceID: mac).synchronize(transport: server, workspace: workspace)
        }
        let restarted = AIConfiguration(client: FakeOpenRouterClient(), keyStore: first.keyStore, defaults: first.defaults)
        #expect(restarted.pendingPreferencesUpload?.outputLanguage == "source")
        #expect(restarted.pendingPreferencesUpload?.enhancementModelID == "fixture/enhancement")
        server.fails = false
        try await AISettingsSynchronizer(configuration: restarted, deviceID: mac).synchronize(transport: server, workspace: workspace)
        #expect(server.preferences?.outputLanguage == "source")
        #expect(restarted.pendingPreferencesUpload == nil)
    }

    @Test("a preference changed during upload stays visible and is sent on the next pass")
    func preservesInFlightEdit() async throws {
        let server = SettingsServer()
        let first = fixture(configured: true)
        first.config.outputLanguage = "ko"
        let sync = AISettingsSynchronizer(configuration: first.config, deviceID: mac)
        server.beforePut = { first.config.outputLanguage = "source" }
        try await sync.synchronize(transport: server, workspace: workspace)
        #expect(first.config.outputLanguage == "source")
        #expect(first.config.pendingPreferencesUpload?.outputLanguage == "source")
        server.beforePut = nil
        try await sync.synchronize(transport: server, workspace: workspace)
        #expect(server.preferences?.outputLanguage == "source")
        #expect(first.config.pendingPreferencesUpload == nil)
    }

    @Test("invalid settings cannot overwrite local preferences")
    func rejectsInvalidPreferences() async throws {
        let server = SettingsServer()
        server.preferences = AISharedPreferences(modelID: "fixture/summary", transcriptionModelID: "fixture/transcription",
            outputLanguage: "invalid", autoGenerate: true, modifiedAt: 1, mutationID: mac)
        let first = fixture(configured: true)
        await #expect(throws: SyncError.self) {
            try await AISettingsSynchronizer(configuration: first.config, deviceID: phone).synchronize(transport: server, workspace: workspace)
        }
        #expect(first.config.outputLanguage == "en")
        #expect(server.uploads.isEmpty)
    }

    @Test("switching Cloudflare workspaces adopts that workspace instead of uploading old edits")
    func isolatesWorkspaces() async throws {
        let first = fixture(configured: true)
        let sync = AISettingsSynchronizer(configuration: first.config, deviceID: mac)
        let server = SettingsServer()
        try await sync.synchronize(transport: server, workspace: workspace)
        first.config.outputLanguage = "source"
        let other = SettingsServer()
        other.preferences = AISharedPreferences(modelID: "fixture/summary", transcriptionModelID: "fixture/transcription",
            outputLanguage: "ko", autoGenerate: false, modifiedAt: 1, mutationID: phone)
        try await sync.synchronize(transport: other, workspace: "https://another.example.test")
        #expect(first.config.outputLanguage == "ko")
        #expect(other.uploads.last?.preferences == nil)
        first.config.setOtherDeviceKeyPresence(true)
        first.config.setSyncContext(endpoint: "https://another.example.test", enabled: false)
        #expect(!first.config.needsKeyForSyncedSettings)
    }

    @Test("a temporarily unreadable key preserves the last known registration")
    func preservesUnknownPresence() async throws {
        let server = SettingsServer()
        let first = fixture(key: "private-fixture", configured: true)
        let sync = AISettingsSynchronizer(configuration: first.config, deviceID: mac)
        try await sync.synchronize(transport: server, workspace: workspace)
        first.keyStore.unavailable = true
        try await sync.synchronize(transport: server, workspace: workspace)
        #expect(server.uploads.last?.device.hasAPIKey == nil)
        #expect(server.devices[mac] == true)
    }

    @Test("model catalog defaults do not masquerade as edits on a new device")
    func catalogRefreshIsNotSharedEdit() async {
        let first = fixture()
        await first.config.refreshModels()
        #expect(first.config.pendingPreferencesUpload == nil)
    }

    @Test("edits made while the server is being read remain pending and win over older settings")
    func preservesEditDuringFetch() async throws {
        let server = SettingsServer()
        server.preferences = AISharedPreferences(modelID: "fixture/summary", transcriptionModelID: "fixture/transcription",
            outputLanguage: "ko", autoGenerate: false, modifiedAt: 1, mutationID: mac)
        let first = fixture()
        server.beforeGet = { first.config.outputLanguage = "source" }
        try await AISettingsSynchronizer(configuration: first.config, deviceID: phone).synchronize(transport: server, workspace: workspace)
        #expect(first.config.outputLanguage == "source")
        #expect(server.preferences?.outputLanguage == "source")
    }

    @Test("a cancelled settings request cannot apply a late server response")
    func ignoresCancelledResponse() async throws {
        let server = SettingsServer()
        server.preferences = AISharedPreferences(modelID: "fixture/summary", transcriptionModelID: "fixture/transcription",
            outputLanguage: "source", autoGenerate: true, modifiedAt: 1, mutationID: mac)
        let first = fixture(configured: true)
        var gate: CheckedContinuation<Void, Never>?
        server.beforeGet = { await withCheckedContinuation { gate = $0 } }
        let request = Task {
            try await AISettingsSynchronizer(configuration: first.config, deviceID: phone).synchronize(transport: server, workspace: workspace)
        }
        for _ in 0..<1000 { if gate != nil { break }; await Task.yield() }
        let continuation = try #require(gate)
        request.cancel()
        continuation.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(first.config.outputLanguage == "en")
        #expect(server.uploads.isEmpty)
    }

    private func fixture(key: String? = nil, configured: Bool = false) -> (config: AIConfiguration, keyStore: SettingsKeyStore, defaults: UserDefaults) {
        let defaults = UserDefaults(suiteName: "AISettingsSync.\(UUID())")!
        if configured {
            defaults.set("fixture/summary", forKey: "ai.modelID")
            defaults.set("fixture/transcription", forKey: "ai.transcriptionModelID")
            defaults.set("en", forKey: "ai.outputLanguage")
        }
        let store = SettingsKeyStore(key: key)
        return (AIConfiguration(client: FakeOpenRouterClient(), keyStore: store, defaults: defaults), store, defaults)
    }
}

@MainActor
private final class SettingsKeyStore: APIKeyStoring {
    var key: String?
    var unavailable = false
    init(key: String?) { self.key = key }
    func read() throws -> String? { if unavailable { throw SyncError.invalidResponse }; return key }
    func save(_ key: String) throws { self.key = key }
    func delete() throws { key = nil }
}

@MainActor
private final class SettingsServer: AISettingsSyncTransport {
    var preferences: AISharedPreferences?
    var devices: [UUID: Bool] = [:]
    var uploads: [AISettingsUpload] = []
    var fails = false
    var beforePut: (() -> Void)?
    var beforeGet: (() async -> Void)?
    func getAISettings(deviceID: UUID) async throws -> AISettingsResponse { await beforeGet?(); return response(deviceID) }
    func putAISettings(_ upload: AISettingsUpload) async throws -> AISettingsResponse {
        if fails { throw SyncError.transferFailed("Synthetic offline error") }
        beforePut?()
        uploads.append(upload)
        if let incoming = upload.preferences, preferences == nil || incoming.wins(over: preferences!) { preferences = incoming }
        if let presence = upload.device.hasAPIKey { devices[upload.device.id] = presence }
        return response(upload.device.id)
    }
    private func response(_ id: UUID) -> AISettingsResponse {
        AISettingsResponse(preferences: preferences, otherDevicesHaveAPIKey: devices.contains { $0.key != id && $0.value })
    }
}
