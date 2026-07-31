@testable import rishi
import Testing
import Foundation




@Suite("RishiBilling package smoke")
struct RishiBilling_PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiBilling.version == "0.1.0-scaffold")
    }


    // BillingPortalEndpoint removed in Phase 13 (Stripe portal handoff
    // replaced by StoreKit 2 `AppStore.showManageSubscriptions(in:)`
    // via ManageSubscriptionPresenter). See 13-07-PLAN.md.
}
