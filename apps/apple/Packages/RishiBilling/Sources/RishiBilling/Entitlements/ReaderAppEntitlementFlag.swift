import Foundation

/// Compile-time gate for Reader-App-entitlement-dependent UI per BILL-03.
///
/// Apple has not yet granted `com.apple.developer.storekit.external-link.account`
/// at planning time (1-2 week review per `READER-APP-ENTITLEMENT.md`). All
/// billing-related external link UI must check `isGranted` and render a
/// text-only fallback when false, per the failure-mode plan and PITFALLS
/// Pitfall 3 (tappable Stripe link without entitlement = automatic rejection).
///
/// When Apple grants the entitlement:
/// 1. Flip `isGranted` to `true` below.
/// 2. Add `com.apple.developer.storekit.external-link.account` to
///    `apps/apple/rishi/rishi/rishi.entitlements` for the App Store +
///    Mac App Store build configurations.
/// 3. Re-test ManageSubscriptionRow + PaywallView render the tappable variants.
///
/// Implemented as a `static let` (not `#if`) so unit tests can verify both
/// branches via injected overrides in `Resolver`.
public enum ReaderAppEntitlementFlag {

    /// `true` once Apple grants `com.apple.developer.storekit.external-link.account`.
    /// FALSE until then — see file header.
    public static let isGranted: Bool = false

    /// Test-only override hook. Production code MUST read `isGranted`; tests
    /// build a `Resolver` struct so they can exercise both branches.
    public struct Resolver: Sendable {
        public let isGranted: Bool
        public init(isGranted: Bool) { self.isGranted = isGranted }
        public static let production = Resolver(isGranted: ReaderAppEntitlementFlag.isGranted)
    }
}
