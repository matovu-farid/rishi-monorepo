/// Pure top-level routing decision for the app shell. Keeps the branch logic
/// out of the SwiftUI view so it is unit-testable.
public enum AppGate: Equatable, Sendable {
    case loading
    case signedOut
    case paywall
    case app

    public static func resolve(
        authProbeComplete: Bool,
        isSignedIn: Bool,
        level: EntitlementLevel
    ) -> AppGate {
        guard authProbeComplete else { return .loading }
        guard isSignedIn else { return .signedOut }
        return level == .pro ? .app : .paywall
    }
}
