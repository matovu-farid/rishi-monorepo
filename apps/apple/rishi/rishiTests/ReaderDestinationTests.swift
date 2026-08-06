import Foundation
import Testing
@testable import rishi

@Suite("Reader destination read-aloud prompts")
struct ReaderDestinationTests {
    @Test("trial allowance failures map to the trial prompt")
    func trialFailureMapsToTrialPrompt() {
        #expect(
            readAloudUpgradeReason(for: .trial(message: "trial exhausted")) == .trialExhausted
        )
    }

    @Test("narration allowance failures map to the narration prompt")
    func narrationFailureMapsToNarrationPrompt() {
        #expect(
            readAloudUpgradeReason(for: .narration(message: "narration exhausted"))
                == .narrationAllowanceExhausted
        )
    }
}
