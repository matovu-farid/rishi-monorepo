import Foundation

/// Source of the Authorization Bearer token used by `WorkerClient`.
/// Phase 3 will ship a Keychain-backed implementation; Phase 2 ships
/// the `StaticTokenProvider` fixture for tests + early integration.
public protocol TokenProvider: Sendable {
    /// Return the current session token, or nil if the user is unauthenticated.
    func token() async -> String?
}

/// Fixed-value `TokenProvider` for tests and pre-auth scenarios.
public struct StaticTokenProvider: TokenProvider {
    private let value: String?

    public init(_ value: String?) {
        self.value = value
    }

    public func token() async -> String? { value }
}
