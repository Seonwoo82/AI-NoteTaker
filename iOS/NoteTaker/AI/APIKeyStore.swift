import Foundation
import Security

@MainActor
final class KeychainAPIKeyStore: APIKeyStoring {
    private let service = "com.seonwoo.notetaker.openrouter"
    private let account = "api-key"

    func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw AIError(message: "저장된 API 키를 읽을 수 없어요. 키를 다시 저장해 주세요.")
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw keychainError("API 키를 읽을 수 없어요", status: status)
        }
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw keychainError("API 키를 업데이트할 수 없어요", status: updateStatus)
            }
        default:
            throw keychainError("API 키를 저장할 수 없어요", status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw keychainError("API 키를 삭제할 수 없어요", status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func keychainError(_ action: String, status: OSStatus) -> AIError {
        AIError(message: "\(action). macOS 키체인 상태 \(status)를 확인해 주세요.")
    }
}

@MainActor
final class InMemoryAPIKeyStore: APIKeyStoring {
    private var key: String?

    init(_ key: String? = nil) {
        self.key = key
    }

    func read() throws -> String? {
        key
    }

    func save(_ key: String) throws {
        self.key = key
    }

    func delete() throws {
        key = nil
    }
}
