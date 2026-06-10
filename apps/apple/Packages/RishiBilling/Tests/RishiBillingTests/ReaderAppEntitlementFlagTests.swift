import Testing
import Foundation
import SwiftUI
@testable import RishiBilling

@MainActor
@Suite("Reader App entitlement gate")
struct ReaderAppEntitlementFlagTests {

    @Test("isGranted defaults to FALSE until Apple grants the entitlement")
    func defaultIsFalse() {
        // Production gate must default OFF — see file header rationale.
        #expect(ReaderAppEntitlementFlag.isGranted == false)
    }

    @Test("Resolver carries the granted flag faithfully")
    func resolverCarriesFlag() {
        let granted = ReaderAppEntitlementFlag.Resolver(isGranted: true)
        let denied  = ReaderAppEntitlementFlag.Resolver(isGranted: false)
        #expect(granted.isGranted == true)
        #expect(denied.isGranted == false)
    }

    @Test("ManageSubscriptionRow constructs in granted state")
    func manageRowGranted() {
        var tapped = 0
        let row = ManageSubscriptionRow(
            entitlement: .init(isGranted: true),
            onTap: { tapped += 1 }
        )
        _ = row.body
        _ = tapped
    }

    @Test("ManageSubscriptionRow constructs in not-granted (text-only) state")
    func manageRowNotGranted() {
        let row = ManageSubscriptionRow(
            entitlement: .init(isGranted: false),
            onTap: {}
        )
        _ = row.body
    }
}
