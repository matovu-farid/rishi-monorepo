@testable import rishi
import Testing


@Suite("No-card trial intro eligibility")
struct NoCardTrialIntroEligibilityTests {

    private let paidPeriod = EntitlementSnapshot.PaidPeriod(
        periodEndMs: 1_700_000_000_000,
        remainingNarrationSeconds: 600,
        remainingVoiceChatSeconds: 600
    )

    @Test("Paid reader and voice snapshots skip the intro")
    func paidReaderAndVoiceSkipIntro() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.readerActive(paidPeriod))
            ) == false
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.voiceActive(paidPeriod))
            ) == false
        )
    }

    @Test("Trial states present the intro")
    func trialStatesPresentIntro() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.trialActive(remainingCredits: 10))
            ) == true
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(for: .success(.trialExhausted)) == true
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(for: .success(.subscriptionExpired)) == true
        )
    }

    @Test("Failed refresh and missing refresh result present the intro")
    func failedOrMissingRefreshPresentsIntro() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .failure(TestError.refreshFailed)
            ) == true
        )
        #expect(NoCardTrialIntroEligibility.shouldPresent(for: nil) == true)
    }
}

private enum TestError: Error {
    case refreshFailed
}
