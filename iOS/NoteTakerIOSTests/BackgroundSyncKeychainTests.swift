import Foundation
import Security
import Testing
@testable import NoteTakerIOS

@MainActor
struct BackgroundSyncKeychainTests {
    @Test("sync credentials saved on iPhone support background refresh after first unlock")
    func savedCredentialsSupportBackgroundRefresh() throws {
        let service = "AutoSyncKeychain.\(UUID())"
        let account = "fixture"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        defer { SecItemDelete(query as CFDictionary) }
        let store = SystemKeychainTokenStore(service: service, account: account)
        try store.saveToken("synthetic-background-token")
        #expect(try store.loadToken() == "synthetic-background-token")
        #expect(try accessibility(query) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    @Test("existing sync credentials migrate without changing the saved token")
    func migratesLegacyCredential() throws {
        let service = "AutoSyncKeychain.\(UUID())"
        let account = "fixture"
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        }
        query[kSecValueData as String] = Data("legacy-synthetic-token".utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
        query.removeValue(forKey: kSecValueData as String)
        query.removeValue(forKey: kSecAttrAccessible as String)
        let store = SystemKeychainTokenStore(service: service, account: account)
        #expect(try store.loadToken() == "legacy-synthetic-token")
        #expect(try accessibility(query) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    private func accessibility(_ query: [String: Any]) throws -> String? {
        var query = query
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }
}
