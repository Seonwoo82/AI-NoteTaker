import Foundation
import Observation
import Security

@MainActor
@Observable
final class SyncSettings {
    var endpoint: String
    var token: String
    var isEnabled: Bool

    private let defaults: UserDefaults
    private let tokenStore: SyncTokenStore

    init(
        defaults: UserDefaults = .standard,
        tokenStore: SyncTokenStore = SystemKeychainTokenStore()
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.endpoint = defaults.string(forKey: "sync.endpoint") ?? ""
        self.isEnabled = defaults.bool(forKey: "sync.isEnabled")
        self.token = (try? tokenStore.loadToken()) ?? ""
    }

    func save() throws {
        if isEnabled {
            _ = try enabledConfiguration()
        }
        try tokenStore.saveToken(token)
        defaults.set(endpoint, forKey: "sync.endpoint")
        defaults.set(isEnabled, forKey: "sync.isEnabled")
    }

    func configuration() throws -> SyncConfiguration {
        try enabledConfiguration()
    }

    func connectionTestConfiguration() throws -> SyncConfiguration {
        try cleanConfiguration()
    }

    private func enabledConfiguration() throws -> SyncConfiguration {
        guard isEnabled else {
            throw SyncError.disabled
        }
        return try cleanConfiguration()
    }

    private func cleanConfiguration() throws -> SyncConfiguration {
        return try SyncConfiguration(endpoint: endpoint, token: token)
    }
}

@MainActor
@Observable
final class SyncCoordinator {
    var isSyncing = false
    var status = ""
    var lastSyncedAt: Date?
    var errorMessage: String?
    var onNotesChanged: ((UUID) -> Void)?

    private let settings: SyncSettings
    private let transportFactory: (SyncConfiguration) -> SyncTransport
    private var currentSync: Task<Void, Never>?
    private var currentConnectionTest: Task<Void, Never>?
    private var activeEngine: SyncEngine?
    private var needsSync = false
    private var settingsGeneration = 0

    init(
        settings: SyncSettings,
        transportFactory: @escaping (SyncConfiguration) -> SyncTransport = { configuration in
            URLSessionSyncTransport(configuration: configuration)
        }
    ) {
        self.settings = settings
        self.transportFactory = transportFactory
    }

    func sync(library: LibraryStore) async {
        if let currentSync {
            needsSync = true
            await currentSync.value
            return
        }
        if let currentConnectionTest {
            currentConnectionTest.cancel()
            await currentConnectionTest.value
        }

        let task = Task { @MainActor in
            await Task.yield()
            isSyncing = true
            errorMessage = nil
            defer {
                isSyncing = false
                currentSync = nil
                activeEngine = nil
                needsSync = false
            }

            do {
                repeat {
                    try Task.checkCancellation()
                    needsSync = false
                    let configuration = try settings.configuration()
                    let engine = SyncEngine(
                        transport: transportFactory(configuration),
                        onNotesChanged: onNotesChanged
                    )
                    activeEngine = engine
                    try await engine.sync(library: library)
                    activeEngine = nil
                } while needsSync
                try Task.checkCancellation()
                status = String(localized: "Synced")
                lastSyncedAt = .now
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        currentSync = task
        await task.value
    }

    func settingsDidChange() {
        settingsGeneration += 1
        needsSync = false
        currentConnectionTest?.cancel()
        activeEngine?.cancel()
        currentSync?.cancel()
    }

    func testConnection() async {
        guard currentSync == nil else { return }
        if let currentConnectionTest {
            await currentConnectionTest.value
            return
        }

        let generation = settingsGeneration
        let task = Task { @MainActor in
            await Task.yield()
            guard currentSync == nil else { return }
            isSyncing = true
            errorMessage = nil
            defer {
                isSyncing = false
                currentConnectionTest = nil
            }

            do {
                try Task.checkCancellation()
                let configuration = try settings.connectionTestConfiguration()
                let health = try await transportFactory(configuration).health()
                try Task.checkCancellation()
                guard settingsGeneration == generation else { return }
                guard health.ok, health.schemaVersion == 1 else {
                    throw SyncError.invalidResponse
                }
                status = String(localized: "Connection OK")
            } catch is CancellationError {
                if settingsGeneration == generation {
                    errorMessage = nil
                }
            } catch {
                guard settingsGeneration == generation else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        currentConnectionTest = task
        await task.value
    }
}

@MainActor
protocol SyncTokenStore: AnyObject {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
}

nonisolated enum SyncKeychainError: LocalizedError, Sendable {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            "Keychain operation failed with status \(status)."
        }
    }
}

@MainActor
final class SystemKeychainTokenStore: SyncTokenStore {
    private let service: String
    private let account: String

    init(
        service: String = "com.seonwoo.notetaker.sync",
        account: String = "cloudflare-worker-token"
    ) {
        self.service = service
        self.account = account
    }

    func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SyncKeychainError.unhandledStatus(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SyncKeychainError.unhandledStatus(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw SyncKeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
