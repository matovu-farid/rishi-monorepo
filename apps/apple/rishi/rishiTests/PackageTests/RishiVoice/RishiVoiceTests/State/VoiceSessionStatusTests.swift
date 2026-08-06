@testable import rishi
import Testing

@Suite("VoiceSessionStatus classification")
struct VoiceSessionStatusTests {

    @Test("trial exhaustion remains classified from the worker error code")
    func trialAllowanceExhaustionIsClassified() {
        let failure = VoiceSessionStartFailure.classify(
            RishiError.network(
                code: WorkerErrorCode.insufficientTrialCredits,
                message: "raw worker detail"
            )
        )

        #expect(failure == .insufficientCredits)
    }

    @Test("paid allowance exhaustion is classified from the worker error code")
    func paidAllowanceExhaustionIsClassified() {
        let failure = VoiceSessionStartFailure.classify(
            RishiError.network(
                code: "INSUFFICIENT_PAID_ALLOWANCE",
                message: "raw worker detail"
            )
        )

        #expect(failure == .insufficientPaidAllowance)
    }
}
