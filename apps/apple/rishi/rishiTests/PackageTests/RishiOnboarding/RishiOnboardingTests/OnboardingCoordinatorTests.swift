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

    @Test("A transition reservation rejects a duplicate action until released")
    func transitionReservationRejectsDuplicates() {
        let c = OnboardingCoordinator(state: InMemoryOnboardingState())

        #expect(c.beginTransition())
        #expect(c.isTransitioning)
        #expect(!c.beginTransition())

        c.endTransition()
        #expect(!c.isTransitioning)
        #expect(c.beginTransition())
        c.endTransition()
    }

    @Test("Back from the language stage returns to Welcome")
    func backFromLanguageReturnsToWelcome() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.voiceLanguagePrimer)

        c.back()

        #expect(c.currentStage == .welcome)
        #expect(await state.hasCompletedOnboarding() == false)
    }

    @Test("Back from the first-reader hint returns to the language stage")
    func backFromHintReturnsToLanguage() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.firstReaderHint)

        c.back()

        #expect(c.currentStage == .voiceLanguagePrimer)
        #expect(await state.hasCompletedOnboarding() == false)
    }

    @Test("Continuing from the language primer advances without completing onboarding")
    func continuingLanguageAdvancesToHint() async {
        let state = InMemoryOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.voiceLanguagePrimer)

        await c.advance()

        #expect(c.currentStage == .firstReaderHint)
        #expect(await state.hasCompletedOnboarding() == false)
    }

    @Test("Back is ignored while completion persistence is suspended")
    func backIsIgnoredWhileCompletionPersistenceIsSuspended() async {
        let state = SuspendedCompletionOnboardingState()
        let c = OnboardingCoordinator(state: state)
        c.setStageForTest(.firstReaderHint)
        #expect(c.beginTransition())

        let advance = Task { @MainActor in
            defer { c.endTransition() }
            await c.advance()
        }

        await state.waitForCompletionWrite()
        c.back()
        #expect(c.currentStage == .firstReaderHint)

        await state.finishCompletionWrite()
        await advance.value

        #expect(c.currentStage == .completed)
        #expect(await state.hasCompletedOnboarding())
        #expect(!c.isTransitioning)
    }
}

private actor SuspendedCompletionOnboardingState: OnboardingState {
    private var completed = false
    private var writeStarted: CheckedContinuation<Void, Never>?
    private var writeRelease: CheckedContinuation<Void, Never>?

    func hasCompletedOnboarding() async -> Bool { completed }
    func setHasCompletedOnboarding(_ value: Bool) async {
        await withCheckedContinuation { continuation in
            writeStarted?.resume()
            writeStarted = nil
            writeRelease = continuation
        }
        completed = value
    }
    func primerShownMic() async -> Bool { false }
    func setPrimerShownMic(_ value: Bool) async {}

    func waitForCompletionWrite() async {
        guard writeRelease == nil else { return }
        await withCheckedContinuation { writeStarted = $0 }
    }

    func finishCompletionWrite() {
        writeRelease?.resume()
        writeRelease = nil
    }
}
