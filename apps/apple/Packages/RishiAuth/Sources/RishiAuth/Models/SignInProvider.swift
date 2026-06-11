import Foundation

/// Tag identifying which provider authenticated the current ``Session``.
///
/// The raw value (`"apple"`) IS the wire shape the worker echoes back in
/// `AuthSessionResponse` provider fields — keep it stable.
///
/// Used for two purposes:
///   1. Keychain serialization — round-trips with the ``Session`` so the app
///      knows which provider re-auth path to take on token refresh.
///   2. `RishiAuthService.deleteAccount()` routing — Apple users go through
///      the worker SIWA revoke endpoint.
///
/// Phase 15 plan 15-03: secondary social-provider case hard-removed; SIWA
/// is the sole social provider for v1.
public enum SignInProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case apple
}
