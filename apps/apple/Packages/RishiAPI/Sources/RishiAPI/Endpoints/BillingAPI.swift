import Foundation

/// `POST /api/billing/portal` — request a one-time Stripe customer-portal URL
/// that the client opens in the system browser.
///
/// Response: `{ "url": "https://billing.stripe.com/p/..." }`
public struct BillingPortalEndpoint: WorkerEndpoint {
    public typealias Response = PortalResponse

    public let method: HTTPMethod = .POST
    public let path: String = "/api/billing/portal"

    public init() {}

    public struct PortalResponse: Decodable, Sendable, Equatable {
        public let url: String
    }
}
