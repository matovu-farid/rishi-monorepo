@testable import rishi
import Testing

@MainActor
@Suite("Onboarding completion gate")
struct OnboardingCompletionGateTests {

    @Test("final advance and completed appearance complete once in either order")
    func callbackOrdersShareOneGate() {
        for finalAdvanceFirst in [true, false] {
            let gate = OnboardingCompletionGate()
            var completionCount = 0
            let finalAdvance = {
                gate.completeOnce { completionCount += 1 }
            }
            let completedAppearance = {
                gate.completeOnce { completionCount += 1 }
            }

            if finalAdvanceFirst {
                finalAdvance()
                completedAppearance()
            } else {
                completedAppearance()
                finalAdvance()
            }
            completedAppearance()
            finalAdvance()

            #expect(completionCount == 1)
        }
    }

    @Test("completion is consumed before callback reentrancy")
    func reentrantCompletionIsIgnored() {
        let gate = OnboardingCompletionGate()
        var completionCount = 0

        gate.completeOnce {
            completionCount += 1
            gate.completeOnce { completionCount += 1 }
        }
        gate.completeOnce { completionCount += 1 }

        #expect(completionCount == 1)
    }
}
