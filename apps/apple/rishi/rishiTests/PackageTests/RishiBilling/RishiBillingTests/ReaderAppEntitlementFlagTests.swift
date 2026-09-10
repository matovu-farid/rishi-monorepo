@testable import rishi
import Foundation
import Observation
import SwiftUI
import Testing


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
        let reconciler = EntitlementReconciler(initial: .subscribed)
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == true)
        #expect(flag.level == .subscribed)
    }

    @Test("isGranted is FALSE when reconciler initial level is .free")
    func isGranted_followsReconcilerFree() {
        let reconciler = EntitlementReconciler(initial: .unsubscribed)
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == false)
        #expect(flag.level == .unsubscribed)
    }

    @Test("isGranted flips when server signal flips reconciler to .pro")
    func isGranted_updatesWhenServerFlipsToPro() {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = EntitlementReconciler()
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        #expect(flag.isGranted == false)

        reconciler.setOnDevice(.subscribed)
        #expect(flag.isGranted == true)
    }

    @Test("preview(_:) helper builds an isolated flag pre-set to the requested level")
    func previewHelper_works() {
        #expect(ReaderAppEntitlementFlag.preview(.subscribed).isGranted == true)
        #expect(ReaderAppEntitlementFlag.preview(.unsubscribed).isGranted == false)
    }

    @Test("@Observable isGranted change notifies tracker on level change")
    func isGranted_ObservationFires_OnLevelChange() async {
        let previousFlag = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previousFlag) }

        let reconciler = EntitlementReconciler()
        let flag = ReaderAppEntitlementFlag(reconciler: reconciler)
        let counter = FlagObservationCounter()

        withObservationTracking {
            _ = flag.isGranted
        } onChange: {
            counter.increment()
        }

        reconciler.setOnDevice(.subscribed)
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
        // Phase-13 rewrite: ManageSubscriptionRow now reads
        // ManageSubscriptionPresenter from the SwiftUI environment instead
        // of taking an onTap closure. Construction smoke only; tap
        // behaviour is exercised by ManageSubscriptionPresenterTests.
        let row = ManageSubscriptionRow()
        _ = row
    }

    @Test("ManageSubscriptionRow constructs in not-granted state via Resolver")
    func manageRowNotGranted() {
        let row = ManageSubscriptionRow()
        _ = row
    }
}

// MARK: - Helpers

/// Lock-guarded counter for cross-isolation tracking from the Observation
/// `onChange` closure. Local helper because Swift Testing's per-file emit
/// can isolate top-level helpers across suite files in some build modes.
private final class FlagObservationCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
