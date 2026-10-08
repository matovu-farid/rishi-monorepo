import Testing
@testable import rishi

@Suite("Billing presentation policy")
struct PaywallRequestPolicyTests {
    @Test("Paid plans suppress ordinary upgrades but retain explicit exhaustion", arguments: [false, true], ["reader", "narration_exhausted", "voice_chat_exhausted"])
    func presentation(_ paid: Bool, _ feature: String) {
        let expected = !paid || feature != "reader"
        #expect(PaywallRequest(feature: feature).shouldPresent(serverPaidActive: paid) == expected)
    }

    @Test("Generic feature identifiers survive normalization", arguments: ["reader", "unknown_feature", "narration_exhausted", "voice_chat_exhausted"])
    func normalizedIdentifier(_ feature: String) {
        let request = PaywallRequest(feature: feature)
        #expect(request.name == feature)
        switch feature {
        case "narration_exhausted": #expect(request == .narrationExhausted)
        case "voice_chat_exhausted": #expect(request == .voiceChatExhausted)
        default: #expect(request == .feature(feature))
        }
    }

    @Test("Device subscription affects management projection without granting server AI access", arguments: [false, true], [false, true])
    func management(_ paid: Bool, _ device: Bool) {
        #expect(SubscriptionManagementPolicy.isSubscribed(serverPaidActive: paid, deviceSubscriptionActive: device) == (paid || device))
        // Device-active never participates in this actual upgrade policy.
        #expect(PaywallRequest.feature("reader").shouldPresent(serverPaidActive: paid) == !paid)
    }

    @MainActor
    @Test("The actual signed-in host applies the same policy and preserves queued requests", arguments: [false, true], ["reader", "narration_exhausted", "voice_chat_exhausted"])
    func host(_ paid: Bool, _ feature: String) {
        let model = SignedInViewModel()
        model.requestPaywall(.feature("previous"), serverPaidActive: false)
        model.requestPaywall(PaywallRequest(feature: feature), serverPaidActive: paid)
        #expect(model.paywallFeature?.name == (paid && feature == "reader" ? "previous" : feature))
        model.dismissPaywall()
        #expect(model.paywallFeature == nil)
    }
}
