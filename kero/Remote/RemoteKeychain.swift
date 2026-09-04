import Foundation
import Security

enum RemoteKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "sh.kero") + ".remote"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = identity
            insertion.merge(attributes) { _, new in new }
            let inserted = SecItemAdd(insertion as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw RemoteKeychainError.status(inserted) }
        } else if status != errSecSuccess {
            throw RemoteKeychainError.status(status)
        }
    }

    static func remove(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

enum RemoteKeychainError: Error {
    case status(OSStatus)
}

extension RemoteKeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? String(localized: "Could not access Keychain.")
        }
    }
}
