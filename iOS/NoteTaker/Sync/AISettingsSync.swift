import Foundation

nonisolated struct AISharedPreferences: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let modelID: String
    var enhancementModelID: String? = nil
    let transcriptionModelID: String
    let outputLanguage: String
    let autoGenerate: Bool
    var transcriptCleanupEnabled: Bool? = nil
    let modifiedAt: Int64
    let mutationID: UUID

    func validate() throws {
        func validModel(_ value: String) -> Bool {
            value.utf8.count <= 256 && (value.isEmpty || value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$", options: .regularExpression) != nil)
        }
        guard schemaVersion == 1, validModel(modelID), validModel(enhancementModelID ?? ""), validModel(transcriptionModelID),
              ["ko", "en", "source"].contains(outputLanguage), modifiedAt >= 0,
              modifiedAt <= 9_007_199_254_740_991 else { throw SyncError.invalidResponse }
    }

    func wins(over other: Self) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && mutationID.uuidString > other.mutationID.uuidString)
    }
}

nonisolated struct AISettingsDevice: Codable, Equatable, Sendable {
    let id: UUID
    let platform: String
    let hasAPIKey: Bool?

    static var currentPlatform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }
}

nonisolated struct AISettingsUpload: Codable, Equatable, Sendable {
    let preferences: AISharedPreferences?
    let device: AISettingsDevice
}

nonisolated struct AISettingsResponse: Codable, Equatable, Sendable {
    let preferences: AISharedPreferences?
    let otherDevicesHaveAPIKey: Bool
}

@MainActor
protocol AISettingsSyncTransport: AnyObject {
    func getAISettings(deviceID: UUID) async throws -> AISettingsResponse
    func putAISettings(_ upload: AISettingsUpload) async throws -> AISettingsResponse
}

@MainActor
final class AISettingsSynchronizer {
    private let configuration: AIConfiguration
    private let deviceID: UUID

    init(configuration: AIConfiguration, deviceID: UUID) {
        self.configuration = configuration
        self.deviceID = deviceID
    }

    func synchronize(transport: any AISettingsSyncTransport, workspace: String) async throws {
        configuration.setSyncContext(endpoint: workspace, enabled: true)
        let previousModels = (configuration.modelID, configuration.enhancementModelID, configuration.transcriptionModelID)
        let remote = try await transport.getAISettings(deviceID: deviceID)
        try Task.checkCancellation()
        try remote.preferences?.validate()
        configuration.setOtherDeviceKeyPresence(remote.otherDevicesHaveAPIKey)
        configuration.preparePreferencesUpload(serverPreferences: remote.preferences)
        let device = AISettingsDevice(id: deviceID, platform: AISettingsDevice.currentPlatform,
                                      hasAPIKey: configuration.keyPresenceForSync())
        try configuration.pendingPreferencesUpload?.validate()
        let response = try await transport.putAISettings(AISettingsUpload(
            preferences: configuration.pendingPreferencesUpload, device: device))
        try Task.checkCancellation()
        try response.preferences?.validate()
        if let preferences = response.preferences { configuration.acceptSharedPreferences(preferences) }
        configuration.setOtherDeviceKeyPresence(response.otherDevicesHaveAPIKey)
        if previousModels.0 != configuration.modelID || previousModels.1 != configuration.enhancementModelID || previousModels.2 != configuration.transcriptionModelID {
            // Catalog availability must not block note/audio synchronization.
            Task { [weak configuration] in await configuration?.refreshModels() }
        }
    }
}
