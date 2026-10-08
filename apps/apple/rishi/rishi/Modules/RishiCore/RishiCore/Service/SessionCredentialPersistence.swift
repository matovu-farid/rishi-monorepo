import Foundation
import Security

/// Safe diagnostics: never carry credential bytes or arbitrary underlying errors.
enum CredentialStorageFailure: Error, Equatable, Sendable {
    case securityStatus(Int32)
    case invalidEncoding
    case invalidRecord
    case unsupportedVersion
    case inconsistentLegacy
    case retirementIncomplete
}

struct LegacyCredentials: Sendable {
    var accessToken: String?
    var refreshToken: String?
    var userID: String?
}

/// The authority serializes these synchronous operations, including migration.
protocol SessionCredentialPersistence: Sendable {
    func readCanonical() throws -> Data?
    func writeCanonical(_ data: Data) throws
    func readLegacy() throws -> LegacyCredentials
    func removeLegacy() throws
}

struct SecuritySessionCredentialPersistence: SessionCredentialPersistence {
    private static let service = "org.fidexa.rishi.session"
    private static let account = "current"

    func readCanonical() throws -> Data? { try read(baseQuery()) }

    func writeCanonical(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery()
            for (key, value) in attributes { query[key] = value }
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialStorageFailure.securityStatus(added) }
        } else if status != errSecSuccess {
            throw CredentialStorageFailure.securityStatus(status)
        }
    }

    func readLegacy() throws -> LegacyCredentials {
        try LegacyCredentials(accessToken: readString("accessToken"),
                              refreshToken: readString("refreshToken"),
                              userID: readString("userId"))
    }

    func removeLegacy() throws {
        for key in ["accessToken", "refreshToken", "userId"] {
            let status = SecItemDelete(legacyQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStorageFailure.securityStatus(status)
            }
        }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    private func legacyQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
    }

    private func readString(_ key: String) throws -> String? {
        guard let data = try read(legacyQuery(key)) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CredentialStorageFailure.invalidEncoding
        }
        return value
    }

    private func read(_ base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageFailure.securityStatus(status) }
        guard let data = result as? Data else { throw CredentialStorageFailure.invalidEncoding }
        return data
    }
}
