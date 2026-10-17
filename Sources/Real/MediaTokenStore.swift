import Foundation
import Security
import LocalAuthentication

/// Companion credentials are scoped to their server URL and stored only in the macOS Keychain.
enum MediaTokenStore {
    private static let service = "local.dan.real.ytmcompanion"

    private struct StorageError: LocalizedError {
        let code: OSStatus
        var errorDescription: String? {
            "Keychain: \((SecCopyErrorMessageString(code, nil) as String?) ?? String(code))"
        }
    }

    private static func query(for serverURL: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(serverURL)]
    }

    private static func account(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        if let url = URL(string: result), url.path.isEmpty { result += "/api/v1" }
        return result
    }

    static func read(for serverURL: String) throws -> String? {
        var attributes = query(for: serverURL)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        // Merely opening settings must not trigger a Keychain authentication prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError(code: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw StorageError(code: errSecDecode)
        }
        return token
    }

    static func save(_ token: String, for serverURL: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { try remove(for: serverURL); return }
        let attributes = query(for: serverURL)
        let value = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(attributes as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var addition = attributes.merging(value) { _, value in value }
            addition[kSecAttrLabel as String] = "Real · YTMDesktop companion"
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(code: status) }
    }

    static func removeAll() throws {
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
        let status = SecItemDelete(attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(code: status) }
    }

    static func remove(for serverURL: String) throws {
        let status = SecItemDelete(query(for: serverURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(code: status) }
    }
}
