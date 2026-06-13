import Foundation

/// Typed errors thrown by Keychain operations.
enum KeychainError: Error, Equatable, Sendable {
    /// Any non-success, non-not-found OSStatus from Security.framework.
    case unexpectedStatus(OSStatus)
    /// Encoder/decoder failure marshalling a Session blob.
    case codec(String)
}

/// Storage seam over Security.framework. Production code uses
/// ``SystemKeychainBackend``; tests inject ``InMemoryKeychainBackend``.
///
/// All methods are `async throws` so the actor wrapping them (``KeychainSessionStore``)
/// can express the operations naturally in Swift Concurrency.
///
/// Implementations are NOT actors — they are stateless structs or NSLock-guarded
/// `final class @unchecked Sendable` — because Swift 6 strict concurrency
/// rejects non-Sendable `[String: Any]` parameters crossing an actor's
/// isolation boundary even when marked `sending`. Per-call serialisation that
/// would normally come from actor isolation is provided one level up by
/// ``KeychainSessionStore`` (which IS an actor).
public protocol KeychainBackend: Sendable {

    /// SecItemAdd — insert a new keychain item. Throws on errSecDuplicateItem.
    func add(query: sending [String: Any]) async throws

    /// SecItemCopyMatching — return the kSecValueData payload, or nil if not found.
    func copyMatching(query: sending [String: Any]) async throws -> Data?

    /// SecItemUpdate — update an existing item's attributes.
    func update(query: sending [String: Any], attributes: sending [String: Any]) async throws

    /// SecItemDelete — remove a keychain item. No-op if not present.
    func delete(query: sending [String: Any]) async throws
}
