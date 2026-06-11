import Foundation

/// `POST /api/billing/verify-receipt` — re-verify a StoreKit 2 signed JWS
/// receipt with the worker. The worker validates the JWS against Apple's
/// `app-store-server-library` x.509 chain, cross-checks `productId` and
/// `transactionId`, and persists the canonical `premium_until` value in
/// `users.premium_until` (see RESEARCH §6.1 and 13-WORKER-CONTRACT.md).
///
/// Response (wire shape — `premiumUntil` is seconds-since-1970 as a JSON
/// number, NOT an ISO string; locked by 14-04):
/// ```json
/// { "verified": true, "premiumUntil": 1812585600, "reason": null }
/// ```
/// or on rejection:
/// ```json
/// { "verified": false, "premiumUntil": null, "reason": "replay_detected" }
/// ```
///
/// `ResponseBody.premiumUntil` decodes the JSON number into `Date?` via a
/// hand-rolled `init(from:)` (see below) so the public Swift API stays a
/// `Date?` while the wire format remains a number of seconds. Default
/// `JSONDecoder()` strategy (`.deferredToDate`) would otherwise misinterpret
/// the number as seconds-since-2001.
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

        // MARK: - Codable
        //
        // The worker emits `premiumUntil` as a JSON **number** of seconds-since-1970
        // (locked in 14-04 SUMMARY + WORKER-CONTRACT-IAP.md). Default
        // `JSONDecoder()` (used by `WorkerClient.send`) decodes `Date` via the
        // `.deferredToDate` strategy, which treats the number as seconds-since
        // Apple's reference date (2001-01-01) — off by 31 years. We bypass the
        // global strategy by decoding `premiumUntil` as `Double?` and converting
        // with `Date(timeIntervalSince1970:)`. Symmetric on encode. This keeps
        // the wire contract a JSON number and the public API a `Date?` without
        // changing the global `WorkerClient` decoder strategy (which other
        // endpoints — e.g. `/api/billing/me` — depend on for ISO strings).

        private enum CodingKeys: String, CodingKey {
            case verified
            case premiumUntil
            case reason
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.verified = try container.decode(Bool.self, forKey: .verified)
            self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
            if let seconds = try container.decodeIfPresent(Double.self, forKey: .premiumUntil) {
                self.premiumUntil = Date(timeIntervalSince1970: seconds)
            } else {
                self.premiumUntil = nil
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(verified, forKey: .verified)
            if let date = premiumUntil {
                try container.encode(date.timeIntervalSince1970, forKey: .premiumUntil)
            } else {
                try container.encodeNil(forKey: .premiumUntil)
            }
            if let reason {
                try container.encode(reason, forKey: .reason)
            } else {
                try container.encodeNil(forKey: .reason)
            }
        }
    }
}
