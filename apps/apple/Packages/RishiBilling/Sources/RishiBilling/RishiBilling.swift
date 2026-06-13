import Foundation

/// RishiBilling — Feature-layer package owning the entitlement check, paywall,
/// and native StoreKit 2 IAP wiring used by Phase 13 to gate Pro features.
///
/// Phase 13 replaces the Phase-11 Stripe portal handoff with native
/// StoreKit IAP. `ManageSubscriptionPresenter` drives
/// `AppStore.showManageSubscriptions(in:)` in-app (with an
/// `itms-apps://apps.apple.com/account/subscriptions` fallback); the
/// `ReaderAppEntitlementFlag` is now an `@Observable` value reading
/// from `EntitlementReconciler` (Transaction.currentEntitlements unioned
/// with the server's premium response — most permissive wins).
///
/// Depends DOWN on RishiCore (models), RishiUIKit (tokens), RishiAPI
/// (WorkerClient + ReceiptVerify endpoint + GetSessionEndpoint), RishiAuth
/// (KeychainSessionStore for token-bearer reads), RishiLogging.
enum RishiBilling {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    static let version = "0.1.0-scaffold"
}
