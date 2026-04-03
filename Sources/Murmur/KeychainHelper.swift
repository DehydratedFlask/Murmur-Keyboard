import Foundation
import Security

/// Minimal Keychain wrapper for storing and retrieving API keys.
/// Uses kSecClassGenericPassword with a fixed access group so the
/// main app and keyboard extension can share credentials.
enum KeychainHelper {

    private static let accessGroup = "group.murmurkeyboard.shared"

    /// Saves a string value to the Keychain for the given service key.
    /// Overwrites any existing value for that key.
    @discardableResult
    static func save(_ value: String, service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        delete(service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Loads a string value from the Keychain for the given service key.
    /// Returns nil if no value exists or the read fails.
    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes the Keychain item for the given service key.
    @discardableResult
    static func delete(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
