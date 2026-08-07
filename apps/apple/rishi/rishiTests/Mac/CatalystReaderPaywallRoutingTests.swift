#if targetEnvironment(macCatalyst)

import Testing
@testable import rishi

@MainActor
@Suite("Catalyst reader paywall routing")
struct CatalystReaderPaywallRoutingTests {
    @Test("narration and Voice Chat requests present plans in the active scene")
    func readerPaywallRequestsPresentPlans() {
        let state = CatalystReaderSubscriptionPresentationState()

        state.handlePaywallRequest("narration_exhausted")

        #expect(state.isPresented)
        #expect(!state.pendingConfirmation)
        #expect(!state.showConfirmation)

        state.isPresented = false
        state.handlePaywallRequest("voice_chat_exhausted")

        #expect(state.isPresented)
    }

    @Test("upgrade requests are forwarded once after the prompt dismisses")
    func readerPromptHandoffForwardsQueuedRequestsOnce() {
        let handoff = ReaderPaywallRequestHandoff()

        handoff.queue("narration_exhausted")
        #expect(handoff.takeAfterPromptDismissal() == "narration_exhausted")
        #expect(handoff.takeAfterPromptDismissal() == nil)

        handoff.queue("voice_chat_exhausted")
        #expect(handoff.takeAfterPromptDismissal() == "voice_chat_exhausted")
    }

    @Test("ordinary prompt dismissal does not request plans")
    func normalPromptDismissalDoesNotRequestPlans() {
        let handoff = ReaderPaywallRequestHandoff()

        #expect(handoff.takeAfterPromptDismissal() == nil)
    }

    @Test("completed purchase confirms after the plans sheet dismisses")
    func completedPurchaseConfirmsAfterDismissal() {
        let state = CatalystReaderSubscriptionPresentationState()
        state.isPresented = true

        state.markPurchaseProcessed()

        #expect(!state.isPresented)
        #expect(state.pendingConfirmation)
        #expect(!state.showConfirmation)

        state.presentConfirmationAfterDismissal()

        #expect(!state.pendingConfirmation)
        #expect(state.showConfirmation)
    }

    @Test("dismissal without a purchase does not show confirmation")
    func dismissalWithoutPurchaseDoesNotConfirm() {
        let state = CatalystReaderSubscriptionPresentationState()

        state.presentConfirmationAfterDismissal()

        #expect(!state.pendingConfirmation)
        #expect(!state.showConfirmation)
    }
}

#endif
