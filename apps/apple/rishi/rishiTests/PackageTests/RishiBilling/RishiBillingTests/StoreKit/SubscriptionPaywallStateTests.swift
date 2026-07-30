@testable import rishi
import StoreKit
import SwiftUI
import Testing

@Suite("Subscription paywall state")
struct SubscriptionPaywallStateTests {
    @Test("unpaid users see the purchase relationship")
    func unpaidUsersCanSubscribe() {
        let state = SubscriptionPaywallPresentation(isPaidActive: false)

        #expect(state.action == .subscribe)
        #expect(state.visibleRelationships == .all)
        #expect(state.showsRestorePurchases)
    }

    @Test("paid users see management and upgrade relationships")
    func paidUsersCanManageAndUpgrade() {
        let state = SubscriptionPaywallPresentation(isPaidActive: true)

        #expect(state.action == .manage)
        #expect(state.visibleRelationships == .upgrade)
        #expect(state.showsRestorePurchases == false)
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

    @Test("Catalyst paywall catalog contains only Mac products")
    func catalystPaywallCatalogIsMacOnly() {
        #expect(RishiProductID.macCatalystReaderAndVoiceProductIDs.count == 4)
        #expect(RishiProductID.macCatalystReaderAndVoiceProductIDs.allSatisfy {
            $0.hasSuffix(".macos")
        })
        #expect(Set(RishiProductID.macCatalystReaderAndVoiceProductIDs).isDisjoint(
            with: Set(RishiProductID.iosReaderAndVoiceProductIDs)
        ))
    }

    @Test("active plan is first when the paywall reopens")
    func activePlanIsMerchandisedFirst() {
        let active = RishiProductID.voiceAnnualMacCatalyst
        let ids = RishiProductID.paywallProductIDs(activeProductID: active)

        #expect(ids.first == active)
        #expect(Set(ids) == Set(RishiProductID.currentPlatformPaywallProductIDs))
    }

    @Test("iOS active products map to equivalent Catalyst products")
    func iosProductsMapToCatalystProducts() {
        #expect(
            RishiProductID.macCatalystEquivalentProductID(for: RishiProductID.readerMonthly)
                == RishiProductID.readerMonthlyMacCatalyst
        )
        #expect(
            RishiProductID.macCatalystEquivalentProductID(for: RishiProductID.readerAnnual)
                == RishiProductID.readerAnnualMacCatalyst
        )
        #expect(
            RishiProductID.macCatalystEquivalentProductID(for: RishiProductID.voiceMonthly)
                == RishiProductID.voiceMonthlyMacCatalyst
        )
        #expect(
            RishiProductID.macCatalystEquivalentProductID(for: RishiProductID.voiceAnnual)
                == RishiProductID.voiceAnnualMacCatalyst
        )
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
