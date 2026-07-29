@testable import rishi
import Testing
import Foundation


@MainActor
@Suite("Onboarding coordinator state machine")
struct OnboardingCoordinatorTests {

    @Test("Initial stage is welcome")
    func initialStageWelcome() {
        let c = OnboardingCoordinator(state: InMemoryOnboardingState())
        #expect(c.currentStage == .welcome)
    }

    @Test("advance walks the full sequence to completed")
    func advanceWalksSequence() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)

        await c.advance(); #expect(c.currentStage == .voiceLanguagePrimer)
        await c.advance(); #expect(c.currentStage == .firstReaderHint)
        await c.advance(); #expect(c.currentStage == .completed)

        #expect(await state.hasCompletedOnboarding() == true)
    }

    @Test("back() moves to previous stage; clamped at welcome")
    func backClampedAtWelcome() {
        let c = OnboardingCoordinator(state: InMemoryOnboardingState())
        c.back()
        #expect(c.currentStage == .welcome)
    }

    @Test("Reaching .completed sets hasCompletedOnboarding")
    func completedSetsFlag() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.firstReaderHint)
        await c.advance()
        #expect(c.currentStage == .completed)
        #expect(await state.hasCompletedOnboarding() == true)
    }
}
