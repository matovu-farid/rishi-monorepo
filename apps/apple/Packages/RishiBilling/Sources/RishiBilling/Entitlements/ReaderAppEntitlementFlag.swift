import Foundation
import Observation

/// Single UI read-site for "is this user premium?" Phase 13-04 replaces
/// the Phase-11 `static let isGranted = false` hardcoded constant with
/// an `@Observable` derived value backed by `EntitlementReconciler`.
///
/// The reconciler unions the on-device `Transaction.currentEntitlements`
/// signal AND the server's premium response — most permissive wins
/// (13-RESEARCH.md §3.4). Reading `isGranted` registers the caller with
/// the Observation framework so SwiftUI views update automatically when
/// the underlying reconciler level changes.
///
/// The nested `Resolver` value type is preserved so the Phase-11 call
/// sites in `PaywallView`, `ManageSubscriptionRow`, `PremiumGateModifier`,
/// and `RishiSettings.BillingSection` / `SettingsScreen` continue to
/// compile UNCHANGED. The value source is the only thing that moved:
/// `Resolver.production` is now a Phase-11 baseline fallback (`false`);
/// Wave-3 wiring will switch call sites to read the live reconciler.
@MainActor
@Observable
public final class ReaderAppEntitlementFlag {

    /// Mirrors `reconciler.level == .pro`. Reading registers with the
    /// Observation framework so SwiftUI views update on change.
    public var isGranted: Bool { reconciler.level == .pro }

    /// Direct access to the reconciled level for callers that need to
    /// differentiate `.free` vs `.pro` (vs future `.trial` / `.team`).
    public var level: EntitlementLevel { reconciler.level }

    private let reconciler: EntitlementReconciler

    public init(reconciler: EntitlementReconciler) {
        self.reconciler = reconciler
    }

    /// Convenience for tests + SwiftUI previews — builds an isolated
    /// reconciler pre-set to `.pro` or `.free` without going through
    /// StoreKit or the worker.
    public static func preview(_ level: EntitlementLevel) -> ReaderAppEntitlementFlag {
        let r = EntitlementReconciler(initial: level)
        return ReaderAppEntitlementFlag(reconciler: r)
    }

    /// Lightweight Sendable snapshot of `isGranted` for the Phase-11
    /// call-site contract (`PaywallView`, `ManageSubscriptionRow`,
    /// `PremiumGateModifier`, RishiSettings). Existing call sites take
    /// `Resolver = .production` so the API survives.
    ///
    /// Wave-3 will switch the call sites to read `ReaderAppEntitlementFlag`
    /// directly via `@Environment`; until then, `Resolver` continues to
    /// be the seam tests inject `.init(isGranted: true/false)` at.
    public struct Resolver: Sendable {
        public let isGranted: Bool
        public init(isGranted: Bool) { self.isGranted = isGranted }

        /// Phase-11 baseline: until Wave-3 wires `.production` to the
        /// live reconciler, default fallback stays `false`.
        public static let production = Resolver(isGranted: false)
    }
}
