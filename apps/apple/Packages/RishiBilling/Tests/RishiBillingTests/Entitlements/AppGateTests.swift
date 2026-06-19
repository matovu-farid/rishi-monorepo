import Testing
@testable import RishiBilling

@Suite struct AppGateTests {
    @Test("loading until auth probe completes")
    func loadingWhileProbing() {
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: false, level: .free) == .loading)
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: true, level: .pro) == .loading)
    }
    @Test("signed out when probe done and no user")
    func signedOut() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: false, level: .free) == .signedOut)
    }
    @Test("signed-in free user gets the paywall")
    func paywallForFree() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, level: .free) == .paywall)
    }
    @Test("signed-in pro (incl. active trial) gets the app")
    func appForPro() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, level: .pro) == .app)
    }
}
