import Foundation

/// RishiBilling — Feature-layer package owning the entitlement check, paywall,
/// and Stripe customer-portal handoff used by Phase 11 to gate Pro features.
///
/// Reader App entitlement (`com.apple.developer.storekit.external-link.account`)
/// gates the visibility of the "Manage Subscription" external-link UI per
/// `READER-APP-ENTITLEMENT.md`. Apple has not yet granted the entitlement at
/// planning time — Plan 11-03 introduces a compile-time
/// `ReaderAppEntitlementFlag` defaulting to OFF; when Apple grants it, flip
/// the flag + add the entitlement key to `rishi.entitlements`.
///
/// Depends DOWN on RishiCore (models), RishiUIKit (tokens), RishiAPI
/// (WorkerClient + BillingPortalEndpoint + GetSessionEndpoint), RishiAuth
/// (KeychainSessionStore for token-bearer reads), RishiLogging.
public enum RishiBilling {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    public static let version = "0.1.0-scaffold"
}
