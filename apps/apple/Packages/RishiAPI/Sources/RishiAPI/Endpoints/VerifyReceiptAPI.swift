import Foundation

/// `POST /api/billing/verify-receipt` — re-verify a StoreKit 2 signed JWS
/// receipt with the worker. The worker validates the JWS against Apple's
/// `app-store-server-library` x.509 chain, cross-checks `productId` and
/// `transactionId`, and persists the canonical `premium_until` value in
/// `users.premium_until` (see RESEARCH §6.1 and 13-WORKER-CONTRACT.md).
///
/// Response:
/// ```json
/// { "verified": true, "premiumUntil": "2027-06-11T00:00:00Z", "reason": null }
/// ```
/// or on rejection:
/// ```json
/// { "verified": false, "premiumUntil": null, "reason": "replay_detected" }
/// ```
///
/// The `RishiBilling.WorkerReceiptVerifier` actor wraps this endpoint so
/// `PurchaseService` and `TransactionListener` can verify receipts via the
/// shared `WorkerClient` retry / auth chain.
public struct VerifyReceiptEndpoint: WorkerEndpointWithBody {
    public typealias Response = ResponseBody

    public let method: HTTPMethod = .POST
    public let path: String = "/api/billing/verify-receipt"
    public let body: Request

    public init(body: Request) {
        self.body = body
    }

    public struct Request: Codable, Sendable, Equatable {
        public let jws: String
        public let productId: String
        public let transactionId: UInt64

        public init(jws: String, productId: String, transactionId: UInt64) {
            self.jws = jws
            self.productId = productId
            self.transactionId = transactionId
        }
    }

    public struct ResponseBody: Codable, Sendable, Equatable {
        public let verified: Bool
        public let premiumUntil: Date?
        public let reason: String?

        public init(verified: Bool, premiumUntil: Date?, reason: String?) {
            self.verified = verified
            self.premiumUntil = premiumUntil
            self.reason = reason
        }
    }
}
