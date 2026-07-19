import Foundation

/// Every Apple product ID Rishi's StoreKit configuration defines, across
/// the legacy 2-product "Pro" tier and the new 4-product Reader/Voice tier
/// (2026-07-17 pricing/trial-launch design doc). Single source of truth for
/// ``Store/fetchProductIDs()`` and ``EntitlementLevel/initialize(productId:)``
/// so the two lists cannot silently drift apart.
///
/// **Decision — ADD, do not replace:** the legacy `.pro.monthly` /
/// `.pro.annual` ids are kept alongside the four new ones. Existing
/// subscribers on the old "Pro" tier must keep a valid, still-fetchable
/// product id and a `.subscribed` ``EntitlementLevel`` until a dedicated
/// grandfathering/migration plan decides how (or whether) to move them onto
/// Reader/Voice — deciding that is explicitly OUT OF SCOPE here. Removing
/// these two ids would silently break `Product.products(for:)` and
/// `EntitlementLevel.initialize` for anyone still on Pro.
public enum RishiProductID {
    public static let proMonthly = "org.fidexa.rishi.pro.monthly"
    public static let proAnnual = "org.fidexa.rishi.pro.annual"

    public static let readerMonthly = "org.fidexa.rishi.reader.monthly"
    public static let readerAnnual = "org.fidexa.rishi.reader.annual"
    public static let voiceMonthly = "org.fidexa.rishi.voice.monthly"
    public static let voiceAnnual = "org.fidexa.rishi.voice.annual"

    /// All six ids Rishi currently defines in StoreKit / App Store Connect.
    /// `Store.fetchProductIDs()` requests exactly this list.
    public static let all: [String] = [
        proMonthly, proAnnual,
        readerMonthly, readerAnnual,
        voiceMonthly, voiceAnnual,
    ]

    /// The four new Reader/Voice ids only, excluding legacy Pro.
    public static let readerAndVoice: [String] = [
        readerMonthly, readerAnnual, voiceMonthly, voiceAnnual,
    ]

    /// Merchandising order for `SubscriptionStoreView(productIDs:)`.
    /// Monthlies first, cheapest entry plan first. Independent of ASC
    /// subscription-group rank (Voice=1, Reader=2), which still governs
    /// upgrade/downgrade when purchased.
    public static let paywallDisplayOrder: [String] = [
        readerMonthly,
        voiceMonthly,
        readerAnnual,
        voiceAnnual,
    ]
}
