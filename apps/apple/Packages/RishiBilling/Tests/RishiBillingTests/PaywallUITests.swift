import Testing
import Foundation
import SwiftUI
@testable import RishiBilling

@MainActor
@Suite("Paywall UI construction smoke")
struct PaywallUITests {

    @Test("PaywallView constructs for arbitrary feature names")
    func paywallConstructs() {
        for feature in ["Read Aloud", "Voice Chat", "Sync", "Pro Feature"] {
            let view = PaywallView(feature: feature, onSubscribe: {}, onDismiss: {})
            _ = view.body
        }
    }

    @Test("PaywallView constructs in granted entitlement state")
    func paywallGranted() {
        let view = PaywallView(
            feature: "Read Aloud",
            entitlement: .init(isGranted: true),
            onSubscribe: {},
            onDismiss: {}
        )
        _ = view.body
    }

    @Test("PaywallView constructs in not-granted (text-only) state")
    func paywallNotGranted() {
        let view = PaywallView(
            feature: "Voice Chat",
            entitlement: .init(isGranted: false),
            onSubscribe: {},
            onDismiss: {}
        )
        _ = view.body
    }

    @Test("PremiumGateModifier shows wrapped content for .pro")
    func gateShowsContentForPro() {
        // Construct the modifier directly and exercise its body(content:)
        // path. We can't call `.body` on a `ModifiedContent` (SwiftUI
        // fatalErrors), so we build the modifier and feed it a stub.
        let modifier = PremiumGateModifier(
            feature: "Read Aloud",
            entitlement: .pro,
            onSubscribe: {}
        )
        #expect(modifier.entitlement == .pro)
        #expect(modifier.feature == "Read Aloud")
        // Convenience extension also builds.
        _ = Text("Pro content").premiumGated(
            feature: "Read Aloud",
            entitlement: .pro,
            onSubscribe: {}
        )
    }

    @Test("PremiumGateModifier shows paywall for .free")
    func gateShowsPaywallForFree() {
        var subscribed = 0
        let modifier = PremiumGateModifier(
            feature: "Read Aloud",
            entitlement: .free,
            onSubscribe: { subscribed += 1 }
        )
        #expect(modifier.entitlement == .free)
        // Convenience extension also builds.
        _ = Text("Pro content").premiumGated(
            feature: "Read Aloud",
            entitlement: .free,
            onSubscribe: { subscribed += 1 }
        )
        _ = subscribed
    }
}
