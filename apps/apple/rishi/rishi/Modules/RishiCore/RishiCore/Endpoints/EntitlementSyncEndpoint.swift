import Foundation

/// `POST /api/billing/entitlement-sync` — submits a StoreKit transaction's
/// signed JWS so the Worker can verify it locally, cross-check the derived
/// `appAccountToken`, persist the entitlement, and start the user's
/// allowance period if needed. See
/// `workers/worker/src/billing/entitlement-sync.ts` and
/// `docs/superpowers/plans/2026-07-17-storekit-entitlement-sync.md`'s
/// "Exports for downstream plans" for the full server-side contract this
/// mirrors.
///
/// `ResponseBody` intentionally does NOT decode the response's `snapshot`
/// field into a typed `EntitlementSnapshot`. That union type, and
/// consuming/caching it, belongs to the separate "entitlement-snapshot-client"
/// plan (which already owns `/api/billing/me`'s response for the same
/// reason). This endpoint only needs to know whether the Worker accepted
/// the transaction; `Decodable`'s default behavior ignores the unknown
/// `snapshot` key, so this stays forward-compatible with no change needed
/// once that other plan lands.
public struct EntitlementSyncEndpoint: WorkerEndpointWithBody {
    public typealias Response = ResponseBody

    public let method: HTTPMethod = .POST
    public let path: String = "/api/billing/entitlement-sync"
    public let body: Request

    public init(body: Request) {
        self.body = body
    }

    public struct Request: Codable, Sendable, Equatable {
        public let transactionJWS: String

        public init(transactionJWS: String) {
            self.transactionJWS = transactionJWS
        }
    }

    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let verified: Bool
        public let reason: String?

        public init(verified: Bool, reason: String?) {
            self.verified = verified
            self.reason = reason
        }
    }
}
