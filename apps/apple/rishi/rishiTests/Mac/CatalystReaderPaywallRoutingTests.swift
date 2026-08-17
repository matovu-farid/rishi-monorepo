#if targetEnvironment(macCatalyst)

import Testing
@testable import rishi

@MainActor
private final class CloseHandleCounter {
    var value = 0
}

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

    @Test("close handle runs its action once")
    func closeHandleIsIdempotent() async {
        let handle = ReaderWindowCloseHandle()
        let counter = CloseHandleCounter()
        handle.register { counter.value += 1 }

        await handle.close()
        await handle.close()

        #expect(counter.value == 1)
    }

    @Test("close handle runs a handler registered after close")
    func closeHandleSupportsLateRegistration() async {
        let handle = ReaderWindowCloseHandle()
        await handle.close()
        let counter = CloseHandleCounter()

        handle.register { counter.value += 1 }
        try? await Task.sleep(for: .milliseconds(10))

        #expect(counter.value == 1)
    }

    @Test("stale window teardown cannot unregister a replacement")
    func staleWindowTeardownPreservesReplacement() async {
        let coordinator = ReaderWindowCoordinator()
        let input = ReaderWindowInput(userID: UUID(), route: .epub(UUID()))
        let staleHandle = ReaderWindowCloseHandle()
        let currentHandle = ReaderWindowCloseHandle()
        let staleCounter = CloseHandleCounter()

        staleHandle.register { staleCounter.value += 1 }
        coordinator.register(input, closeHandle: staleHandle)
        coordinator.activate(input)
        coordinator.register(input, closeHandle: currentHandle)

        await coordinator.unregister(input, closeHandle: staleHandle)

        #expect(coordinator.openWindows[input.id] == input)
        #expect(coordinator.activeReader == input)
        #expect(staleCounter.value == 1)

        await coordinator.unregister(input, closeHandle: currentHandle)
        #expect(coordinator.openWindows[input.id] == nil)
        #expect(coordinator.activeReader == nil)
    }

    @Test("scene disconnect closes the registered reader handle")
    func sceneDisconnectClosesRegisteredHandle() async {
        let coordinator = ReaderWindowCoordinator()
        let input = ReaderWindowInput(userID: UUID(), route: .epub(UUID()))
        let handle = ReaderWindowCloseHandle()
        let counter = CloseHandleCounter()
        handle.register { counter.value += 1 }
        coordinator.register(input, closeHandle: handle)

        await coordinator.sceneDidDisconnect(input, closeHandle: handle)

        #expect(counter.value == 1)
        #expect(coordinator.openWindows[input.id] == nil)
    }
}

#endif
