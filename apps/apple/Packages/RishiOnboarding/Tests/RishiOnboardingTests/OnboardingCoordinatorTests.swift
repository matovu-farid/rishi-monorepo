import Testing
import Foundation
@testable import RishiOnboarding

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

        await c.advance(); #expect(c.currentStage == .signIn)
        await c.advance(); #expect(c.currentStage == .sampleOrImport)
        await c.advance(); #expect(c.currentStage == .micPrimer)
        await c.advance(); #expect(c.currentStage == .notificationsPrimer)
        await c.advance(); #expect(c.currentStage == .firstReaderHint)
        await c.advance(); #expect(c.currentStage == .completed)

        #expect(await state.hasCompletedOnboarding() == true)
    }

    @Test("Mic primer is skipped when state.primerShownMic is true")
    func skipMicPrimerIfShown() async {
        let state = InMemoryOnboardingState()
        await state.setPrimerShownMic(true)
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.sampleOrImport)
        await c.advance()
        #expect(c.currentStage == .notificationsPrimer)
    }

    @Test("Notifications primer is skipped when state.primerShownNotifications is true")
    func skipNotifsPrimerIfShown() async {
        let state = InMemoryOnboardingState()
        await state.setPrimerShownMic(false)
        await state.setPrimerShownNotifications(true)
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.micPrimer)
        await c.advance()
        #expect(c.currentStage == .firstReaderHint)
    }

    @Test("back() moves to previous stage; clamped at welcome")
    func backClampedAtWelcome() {
        let c = OnboardingCoordinator(state: InMemoryOnboardingState())
        c.back()
        #expect(c.currentStage == .welcome)
        c.setStageForTest(.signIn)
        c.back()
        #expect(c.currentStage == .welcome)
        c.setStageForTest(.sampleOrImport)
        c.back()
        #expect(c.currentStage == .signIn)
    }

    @Test("skipCurrentStage on micPrimer marks primerShownMic + advances")
    func skipMicMarksShown() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.micPrimer)
        await c.skipCurrentStage()
        #expect(c.currentStage == .notificationsPrimer)
        #expect(await state.primerShownMic() == true)
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
