import Foundation
import Security

/// Production ``KeychainBackend`` backed by Security.framework's `SecItem*` APIs.
///
/// Stateless and Sendable — every call is independent so concurrent reads/writes
/// from the wrapping ``KeychainSessionStore`` actor are safe. Items are stored
/// with `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock` so they survive
/// background fetch and silent push handoff per PITFALLS.md
/// ("Keychain pitfall: wrong accessibility class").
public struct SystemKeychainBackend: KeychainBackend {

    public init() {}

    public func add(query: [String: Any]) async throws {
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func copyMatching(query: [String: Any]) async throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func update(query: [String: Any], attributes: [String: Any]) async throws {
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(query: [String: Any]) async throws {
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
