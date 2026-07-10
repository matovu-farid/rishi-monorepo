import Testing
import Foundation
@testable import RishiOnboarding

@Suite(.serialized)
struct OnboardingStateTests {

    private func freshDefaults() -> UserDefaults {
        let name = "test.onboarding.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("All flags default to FALSE on first run")
    func defaultsAreFalse() async {
        let s = UserDefaultsOnboardingState(defaults: freshDefaults())
        #expect(await s.hasCompletedOnboarding() == false)
        #expect(await s.primerShownMic() == false)
    }

    @Test("setHasCompletedOnboarding(true) persists")
    func setCompletedPersists() async {
        let d = freshDefaults()
        let s = UserDefaultsOnboardingState(defaults: d)
        await s.setHasCompletedOnboarding(true)
        #expect(await s.hasCompletedOnboarding() == true)
        #expect(d.bool(forKey: "onboarding.completed") == true)
    }

    @Test("setPrimerShownMic(true) persists")
    func setMicPrimerPersists() async {
        let s = UserDefaultsOnboardingState(defaults: freshDefaults())
        await s.setPrimerShownMic(true)
        #expect(await s.primerShownMic() == true)
    }

    @Test("InMemoryOnboardingState round-trips the remaining flags")
    func inMemoryRoundTrips() async {
        let s = InMemoryOnboardingState()
        await s.setHasCompletedOnboarding(true)
        await s.setPrimerShownMic(true)
        #expect(await s.hasCompletedOnboarding() == true)
        #expect(await s.primerShownMic() == true)
    }
}
