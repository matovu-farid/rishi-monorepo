import Foundation
import Security
import os

/// Test-only ``KeychainBackend``. Stores items keyed by `(service, account)` — the
/// same composite key Security.framework uses for `kSecClassGenericPassword`.
///
/// Implemented as a `final class @unchecked Sendable` (NOT an actor) because
/// Swift 6 strict concurrency rejects `[String: Any]` parameters crossing an
/// actor's isolation boundary even when marked `sending` — the protocol witness
/// gets called from arbitrary isolation domains and the dictionary type itself
/// is non-Sendable. The same `@unchecked Sendable` pattern is used by
/// `FakeChatService` elsewhere in the codebase per Phase 01 STATE.md.
/// `OSAllocatedUnfairLock` is the async-safe lock primitive (NSLock's
/// `lock()/unlock()` are unavailable from `async` contexts in Swift 6).
///
/// Production code MUST NOT depend on this type; it lives in the main module
/// only so Swift Testing can find it under `@testable import RishiAuth`.
final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let storage = OSAllocatedUnfairLock<[Key: Data]>(initialState: [:])

    init() {}

    /// Snapshot accessor for assertions. Test-only.
    func snapshotItemCount() -> Int {
        storage.withLock { $0.count }
    }

    func add(query: sending [String: Any]) async throws {
        let extracted = Self.extract(from: query)
        guard let key = extracted.key else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        guard let data = extracted.data else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        try storage.withLock { items in
            if items[key] != nil {
                throw KeychainError.unexpectedStatus(errSecDuplicateItem)
            }
            items[key] = data
        }
    }

    func copyMatching(query: sending [String: Any]) async throws -> Data? {
        let extracted = Self.extract(from: query)
        guard let key = extracted.key else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        return storage.withLock { $0[key] }
    }

    func update(query: sending [String: Any], attributes: sending [String: Any]) async throws {
        let extractedQuery = Self.extract(from: query)
        let extractedAttrs = Self.extract(from: attributes)
        guard let key = extractedQuery.key else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        try storage.withLock { items in
            guard items[key] != nil else {
                throw KeychainError.unexpectedStatus(errSecItemNotFound)
            }
            if let newData = extractedAttrs.data {
                items[key] = newData
            }
        }
    }

    func delete(query: sending [String: Any]) async throws {
        let extracted = Self.extract(from: query)
        guard let key = extracted.key else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        storage.withLock { items in
            _ = items.removeValue(forKey: key)
        }
    }

    /// Lifts the only fields we care about (`service`, `account`, `data`) out of a
    /// non-Sendable `[String: Any]` query into Sendable scalars before crossing
    /// any concurrency boundary. Returning the dictionary itself isn't safe;
    /// returning these scalars is.
    private static func extract(from query: [String: Any]) -> (key: Key?, data: Data?) {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let data = query[kSecValueData as String] as? Data
        let key: Key? = {
            guard let service, let account else { return nil }
            return Key(service: service, account: account)
        }()
        return (key, data)
    }
}
