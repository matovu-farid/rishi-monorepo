@testable import rishi
import Testing


@Suite struct AppGateTests {
    @Test("loading until auth probe completes")
    func loadingWhileProbing() {
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: false, entitlementResolved: false, level: .free) == .loading)
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: true, entitlementResolved: true, level: .pro) == .loading)
    }
    @Test("signed out when probe done and no user")
    func signedOut() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: false, entitlementResolved: false, level: .free) == .signedOut)
    }
    @Test("signed-in free user gets the paywall once entitlement is resolved")
    func paywallForResolvedFree() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, entitlementResolved: true, level: .free) == .paywall)
    }
    @Test("signed-in free but NOT yet resolved shows loading, not the paywall")
    func loadingWhileEntitlementUnresolved() {
        // Avoids flashing the paywall to a Pro/trial user before the first
        // server entitlement answer arrives.
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, entitlementResolved: false, level: .free) == .loading)
    }
    @Test("signed-in pro (incl. active trial) gets the app even before resolution")
    func appForPro() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, entitlementResolved: false, level: .pro) == .app)
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, entitlementResolved: true, level: .pro) == .app)
    }
}
