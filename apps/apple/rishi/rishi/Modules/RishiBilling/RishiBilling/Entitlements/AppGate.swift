/// Pure top-level routing decision for the app shell. Keeps the branch logic
/// out of the SwiftUI view so it is unit-testable.
@available(iOS 18.4, macOS 15.4, *)
public enum AppGate: Equatable, Sendable {
    case loading
    case signedOut
    case paywall
    case app

    /// - entitlementResolved: whether the first server entitlement answer has
    ///   arrived this session. A signed-in `.free` user shows `.loading` (not
    ///   `.paywall`) until this is true, so a Pro/trial user whose cache hasn't
    ///   confirmed yet never flashes the paywall before get-session resolves.
    public static func resolve(
        authProbeComplete: Bool,
        isSignedIn: Bool,
        entitlementResolved: Bool,
        level: EntitlementLevel
    ) -> AppGate {
        guard authProbeComplete else { return .loading }
        guard isSignedIn else { return .signedOut }
        if level == .subscribed { return .app }
        return entitlementResolved ? .paywall : .loading
    }
}
