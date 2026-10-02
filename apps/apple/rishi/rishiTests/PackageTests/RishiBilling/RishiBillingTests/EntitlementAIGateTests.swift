import Foundation
import Testing
@testable import rishi

@Suite("Entitlement AI feature gate")
struct EntitlementAIGateTests {
    @Test("a successful refresh result takes precedence over a stale expired snapshot")
    func successfulRefreshResultWinsOverStoredSnapshot() {
        let storedSnapshot = EntitlementSnapshot.subscriptionExpired
        let refreshedSnapshot = EntitlementSnapshot.trialActive(remainingCredits: 8)

        let snapshot = EntitlementAIGate.snapshotAfterRefresh(
            .success(refreshedSnapshot),
            fallingBackTo: storedSnapshot
        )

        #expect(snapshot == refreshedSnapshot)
        #expect(snapshot?.blockReason(for: .narration) == nil)
        #expect(snapshot?.blockReason(for: .voiceChat) == nil)
    }

    @Test("a failed refresh falls back to the latest stored snapshot")
    func failedRefreshUsesStoredSnapshot() {
        let storedSnapshot = EntitlementSnapshot.trialActive(remainingCredits: 3)

        let snapshot = EntitlementAIGate.snapshotAfterRefresh(
            .failure(EntitlementRefreshError.accountChanged),
            fallingBackTo: storedSnapshot
        )

        #expect(snapshot == storedSnapshot)
    }
}
