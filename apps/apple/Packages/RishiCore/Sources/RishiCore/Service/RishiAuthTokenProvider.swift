import Foundation

/// ``RishiAPI.TokenProvider`` implementation backed by
/// ``KeychainSessionStore``.
///
/// Reads the keychain on every ``token()`` call so token rotation is picked up
/// immediately by ``WorkerClient`` without needing an explicit refresh hook.
/// The cost is one keychain read per outbound HTTP request — measured in
/// milliseconds and dwarfed by the network round-trip itself.
///
/// Throws from the keychain are swallowed and treated as "no token available";
/// ``WorkerClient`` handles `nil` tokens as the unauthenticated case (no
/// `Authorization` header attached).
public struct RishiAuthTokenProvider: TokenProvider {

    private let keychain: KeychainSessionStore

    public init(keychain: KeychainSessionStore) {
        self.keychain = keychain
    }

    public func token() async -> String? {
        do {
            return try await keychain.load()?.token
        } catch {
            return nil
        }
    }
}
