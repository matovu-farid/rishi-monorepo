import Foundation

/// Local entitlement projection. Mirrors `GetSessionEndpoint.ProfileResponse.hasPro`
/// (the worker source of truth) but typed so UI code reads `.pro` instead of a bool.
///
/// Persistence is rawValue `String` — small + forward-compatible (we can add
/// `.trial` or `.team` later without breaking persisted values).
public enum EntitlementLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case free
    case pro

    /// Initialise from the worker's `hasPro` flag.
    public init(hasPro: Bool) {
        self = hasPro ? .pro : .free
    }
}
