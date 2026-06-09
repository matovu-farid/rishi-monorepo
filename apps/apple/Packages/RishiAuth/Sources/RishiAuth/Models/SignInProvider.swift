import Foundation

/// Tag identifying which provider authenticated the current ``Session``.
///
/// The raw values (`"apple"`, `"google"`) ARE the wire shape the worker echoes
/// back in `AuthSessionResponse` provider fields — keep them stable.
///
/// Used for two purposes:
///   1. Keychain serialization — round-trips with the ``Session`` so the app
///      knows which provider re-auth path to take on token refresh.
///   2. `RishiAuthService.deleteAccount()` branching — Apple users go through
///      the worker SIWA revoke endpoint; Google users hit the generic delete.
public enum SignInProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case apple
    case google
}
