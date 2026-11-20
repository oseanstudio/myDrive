// macOS Keychain adapter mirroring Windows/App/CredentialStore.cs:
// one generic-password item per secret, service "myDrive", account
// "myDrive/<bookmark-id>" (or the special "syncthing-local-api" account).
import Foundation

enum Keychain {
    private static let service = "myDrive"

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Keychain returned status \(status)."
            }
        }
    }

    static func setData(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let update = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = base
            attributes.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        } else if update != errSecSuccess {
            throw KeychainError.unhandled(update)
        }
    }

    static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Deleting a missing item is not an error (matches the Windows adapter).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveCredentials(_ credentials: Credentials, id: String) throws {
        let data = try JSONEncoder().encode(credentials)
        try setData(data, account: "myDrive/\(id)")
    }

    static func readCredentials(id: String) -> Credentials {
        guard let data = data(account: "myDrive/\(id)") else { return Credentials() }
        return (try? JSONDecoder().decode(Credentials.self, from: data)) ?? Credentials()
    }

    static func deleteCredentials(id: String) {
        delete(account: "myDrive/\(id)")
    }

    static func saveSyncthingAPIKey(_ key: String) throws {
        try setData(Data(key.utf8), account: "syncthing-local-api")
    }

    static func syncthingAPIKey() -> String {
        guard let data = data(account: "syncthing-local-api") else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
