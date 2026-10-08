@testable import rishi
import Testing
import SwiftUI

@MainActor
@Suite("Onboarding progress")
struct OnboardingProgressTests {

    @Test("Each visible onboarding stage maps to its position in the introduction")
    func stagesMapToIntroductionPositions() {
        #expect(OnboardingCoordinator.Stage.welcome.introStep == 1)
        #expect(OnboardingCoordinator.Stage.voiceLanguagePrimer.introStep == 2)
        #expect(OnboardingCoordinator.Stage.firstReaderHint.introStep == 3)
        #expect(OnboardingCoordinator.Stage.completed.introStep == nil)
    }

    @Test("Progress label constructs for each visible step")
    func progressLabelConstructsForVisibleSteps() {
        for step in 1...3 {
            _ = OnboardingProgressView(step: step).body
        }
    }
}
