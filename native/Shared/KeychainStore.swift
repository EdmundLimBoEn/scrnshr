// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import Foundation
import Security

enum KeychainStore {
    static func save(_ data: Data, account: String) throws {
        let query = query(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if result != errSecSuccess {
            throw KeychainError(status: result)
        }
    }

    static func load(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    static func delete(account: String) {
        let query = query(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private static func query(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: "systems.edmundlim.scrnshr",
                                     kSecAttrAccount as String: account]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not save the device credential in Keychain (\(status))." }
    }
}
