import Foundation

/// `GET /api/billing/me` — the authoritative entitlement snapshot for the
/// signed-in user. See `EntitlementSnapshot` for the decoded shape and
/// `docs/superpowers/plans/2026-07-17-billing-me-entitlement-snapshot.md`
/// for the exact wire contract this mirrors.
///
/// The Worker sends `Cache-Control: private, max-age=30, must-revalidate`
/// on this response. This client layers no additional caching on top —
/// `RishiBilling.EntitlementService.refreshSnapshot()` decides when to call
/// this endpoint (launch, foreground; see that type and `rishiApp.swift`).
public struct BillingMeEndpoint: WorkerEndpoint {
    public typealias Response = EntitlementSnapshot

    public let method: HTTPMethod = .GET
    public let path: String = "/api/billing/me"

    public init() {}
}
