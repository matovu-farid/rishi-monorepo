import Foundation

/// Sendable value type for crossing actor boundaries.
///
/// Per Phase 13 RESEARCH §10 Pitfall 14: `StoreKit.Product` is `Sendable`,
/// but returning a `[Product]` from an actor to a `@MainActor @Observable`
/// class can produce Swift 6 strict-concurrency warnings depending on
/// accessor design. We ship explicit value-type snapshots so the UI never
/// holds a raw `Product`.
public struct ProductSnapshot: Sendable, Equatable, Identifiable {

    public enum Period: String, Sendable, Equatable {
        case week, month, year, unknown
    }

    /// Product identifier (e.g. `"org.fidexa.rishi.pro.monthly"`).
    public let id: String
    /// Localized display name from `Product.displayName`.
    public let displayName: String
    /// Localized formatted price string from `Product.displayPrice` (e.g. `"$4.99"`).
    public let displayPrice: String
    /// Subscription period unit derived from `Product.SubscriptionPeriod.unit`.
    public let period: Period
    /// Localized period description (e.g. `"month"`, `"year"`) suitable for UI copy.
    public let periodLocalized: String
    /// Whether the current user is eligible for the introductory offer.
    public let isEligibleForIntroOffer: Bool
    /// Human-readable intro offer description (e.g. `"7-day free trial"`).
    /// `nil` when ineligible or no intro offer configured.
    public let introOfferDescription: String?

    public init(
        id: String,
        displayName: String,
        displayPrice: String,
        period: Period,
        periodLocalized: String,
        isEligibleForIntroOffer: Bool,
        introOfferDescription: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.period = period
        self.periodLocalized = periodLocalized
        self.isEligibleForIntroOffer = isEligibleForIntroOffer
        self.introOfferDescription = introOfferDescription
    }
}

/// Sendable two-tier catalog snapshot. UI binds to this directly.
public struct ProductCatalog: Sendable, Equatable {
    public let monthly: ProductSnapshot?
    public let annual: ProductSnapshot?

    public var hasAny: Bool { monthly != nil || annual != nil }

    public init(monthly: ProductSnapshot?, annual: ProductSnapshot?) {
        self.monthly = monthly
        self.annual = annual
    }

    public static let empty = ProductCatalog(monthly: nil, annual: nil)
}
