@testable import rishi
import StoreKit
import Testing

@Suite("Subscription paywall state")
struct SubscriptionPaywallStateTests {
    @Test("unpaid users see the purchase relationship")
    func unpaidUsersCanSubscribe() {
        let state = SubscriptionPaywallPresentation(isPaidActive: false)

        #expect(state.action == .subscribe)
        #expect(state.visibleRelationships == .all)
    }

    @Test("paid users see management and upgrade relationships")
    func paidUsersCanManageAndUpgrade() {
        let state = SubscriptionPaywallPresentation(isPaidActive: true)

        #expect(state.action == .manage)
        #expect(state.visibleRelationships == .upgrade)
    }

    @Test("paywall catalog is platform-scoped")
    func paywallDoesNotIncludeMacProductsOnIOS() {
        #if !targetEnvironment(macCatalyst)
        #expect(RishiProductID.currentPlatformPaywallProductIDs.count == 4)
        #expect(
            RishiProductID.currentPlatformPaywallProductIDs.allSatisfy {
                !$0.hasSuffix(".macos")
            }
        )
        #endif
    }

    @Test("StoreKit-active users never see stale trial credits")
    func paidUsersDoNotSeeTrialCreditsDuringServerRefresh() {
        #expect(
            RemainingAllowanceView.shouldShowTrialCredits(
                snapshot: .trialActive(remainingCredits: 134),
                storeKitIsSubscribed: true
            ) == false
        )
        #expect(
            RemainingAllowanceView.shouldShowTrialCredits(
                snapshot: .trialActive(remainingCredits: 134),
                storeKitIsSubscribed: false
            ) == true
        )
    }

    @Test("restore copy treats no entitlement as an informational result")
    func nothingToRestoreIsNotAnError() {
        #expect(
            RestoreMessage.forOutcome(.nothingToRestore)
                == "No purchases were found to restore."
        )
    }

    @Test("restore failures use stable recovery copy")
    func restoreFailuresDoNotLeakInternalErrors() {
        let message = RestoreMessage.forError(
            RestoreError.syncFailed("internal StoreKit details")
        )

        #expect(message == "We couldn’t verify your purchases right now. Check your Apple ID connection and try again.")
        #expect(!message.contains("internal StoreKit details"))
        #expect(!message.contains("RestoreError"))
    }
}
