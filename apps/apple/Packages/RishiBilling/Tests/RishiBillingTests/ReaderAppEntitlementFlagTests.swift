import Foundation
import Observation
import SwiftUI
import Testing
@testable import RishiBilling

/// `ReaderAppEntitlementFlag` is the single UI read-site for "is this user
/// premium?" Phase 13-04 replaces the hardcoded `static let isGranted =
/// false` constant with a derived value from `EntitlementReconciler`. The
/// instance `isGranted` follows `reconciler.level == .pro`.
///
/// The nested `Resolver` value type is preserved for existing call sites
/// in `PaywallView`, `ManageSubscriptionRow`, `PremiumGateModifier`, and
/// RishiSettings — see `manageRowGranted` / `manageRowNotGranted` carry-
/// over coverage at the bottom of the suite.
@MainActor
@Suite("ReaderAppEntitlementFlag reads through EntitlementReconciler", .serialized)
struct ReaderAppEntitlementFlagTests {

    // MARK: - Reconciler-backed isGranted

    @Test("isGranted is TRUE when reconciler initial level is .pro")
    func isGranted_followsReconcilerPro() {
        let reconciler = EntitlementReconciler(initial: .pro)
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == true)
        #expect(flag.level == .pro)
    }

    @Test("isGranted is FALSE when reconciler initial level is .free")
    func isGranted_followsReconcilerFree() {
        let reconciler = EntitlementReconciler(initial: .free)
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == false)
        #expect(flag.level == .free)
    }

    @Test("isGranted flips when server signal flips reconciler to .pro")
    func isGranted_updatesWhenServerFlipsToPro() {
        let reconciler = EntitlementReconciler()
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == false)

        reconciler.setServer(.pro)
        #expect(flag.isGranted == true)
    }

    @Test("preview(_:) helper builds an isolated flag pre-set to the requested level")
    func previewHelper_works() {
        #expect(ReaderAppEntitlementFlag.preview(.pro).isGranted == true)
        #expect(ReaderAppEntitlementFlag.preview(.free).isGranted == false)
    }

    @Test("@Observable isGranted change notifies tracker on level change")
    func isGranted_ObservationFires_OnLevelChange() async {
        let reconciler = EntitlementReconciler()
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        let counter = LockedCounter()

        withObservationTracking {
            _ = flag.isGranted
        } onChange: {
            counter.increment()
        }

        reconciler.setServer(.pro)
        await Task.yield()

        #expect(counter.value == 1)
    }

    // MARK: - Resolver carry-over (existing API preserved)

    @Test("Resolver carries the granted flag faithfully — call-site API preserved")
    func resolverCarriesFlag() {
        let granted = ReaderAppEntitlementFlag.Resolver(isGranted: true)
        let denied  = ReaderAppEntitlementFlag.Resolver(isGranted: false)
        #expect(granted.isGranted == true)
        #expect(denied.isGranted == false)
    }

    @Test("ManageSubscriptionRow constructs in granted state via Resolver")
    func manageRowGranted() {
        var tapped = 0
        let row = ManageSubscriptionRow(
            entitlement: .init(isGranted: true),
            onTap: { tapped += 1 }
        )
        _ = row.body
        _ = tapped
    }

    @Test("ManageSubscriptionRow constructs in not-granted state via Resolver")
    func manageRowNotGranted() {
        let row = ManageSubscriptionRow(
            entitlement: .init(isGranted: false),
            onTap: {}
        )
        _ = row.body
    }
}
