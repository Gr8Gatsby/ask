import Foundation
import Security

/// Stores and retrieves script configuration secrets from the macOS Keychain.
/// Keys are stored under service "com.ask.config", account "<scriptID>.<key>".
final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()
    private let service = "com.ask.config"

    private init() {}

    // MARK: - Read

    func get(scriptID: String, key: String) -> String? {
        let account = "\(scriptID).\(key)"
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    // MARK: - Write

    func set(scriptID: String, key: String, value: String) throws {
        let account = "\(scriptID).\(key)"
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Try to update an existing item first
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            throw KeychainError.securityError(status)
        }
    }

    // MARK: - Delete

    func delete(scriptID: String, key: String) {
        let account = "\(scriptID).\(key)"
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Env vars for script launch

    /// Returns all stored config values for a script as ASK_CONFIG_* env vars.
    func envVars(scriptID: String, configItems: [ScriptConfigItem]) -> [String: String] {
        var env: [String: String] = [:]
        for item in configItems {
            if let value = get(scriptID: scriptID, key: item.key) {
                let envKey = "ASK_CONFIG_\(item.key.uppercased())"
                env[envKey] = value
            }
        }
        return env
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case securityError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value as UTF-8"
        case .securityError(let status):
            return "Keychain error: \(status)"
        }
    }
}
