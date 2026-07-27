import Foundation

/// Every Apple product ID Rishi accepts, across the legacy Pro tier and the
/// platform-specific Reader/Voice products. Single source of truth for
/// ``Store/fetchProductIDs()`` and ``EntitlementLevel/initialize(productId:)``
/// so product loading and entitlement recognition cannot silently drift apart.
///
/// **Decision — ADD, do not replace:** the legacy `.pro.monthly` /
/// `.pro.annual` ids remain in the explicit entitlement allow-list. Existing
/// subscribers on the old "Pro" tier keep a `.subscribed`
/// ``EntitlementLevel`` until a dedicated grandfathering/migration plan
/// decides how (or whether) to move them onto Reader/Voice. Removing these
/// two ids would silently break entitlement recognition for anyone still on
/// Pro; they are intentionally excluded from the new Reader/Voice paywall.
public enum RishiProductID {
    public static let proMonthly = "org.fidexa.rishi.pro.monthly"
    public static let proAnnual = "org.fidexa.rishi.pro.annual"

    // This is the live App Store Connect product ID. It predates the
    // org.fidexa prefix used by the other Reader/Voice products.
    public static let readerMonthly = "rishi.reader.monthly"
    public static let readerAnnual = "org.fidexa.rishi.reader.annual"
    public static let voiceMonthly = "org.fidexa.rishi.voice.monthly"
    public static let voiceAnnual = "org.fidexa.rishi.voice.annual"

    public static let voiceMonthlyMacCatalyst = "org.fidexa.rishi.voice.monthly.macos"
    public static let voiceAnnualMacCatalyst = "org.fidexa.rishi.voice.annual.macos"
    public static let readerMonthlyMacCatalyst = "org.fidexa.rishi.reader.monthly.macos"
    public static let readerAnnualMacCatalyst = "org.fidexa.rishi.reader.annual.macos"

    /// All live and grandfathered IDs Rishi recognizes in StoreKit / App Store Connect.
    /// `EntitlementLevel.initialize(productId:)` validates against this list;
    /// `Store.fetchProductIDs()` selects the current-platform subset below.
    public static let all: [String] = [
        proMonthly, proAnnual,
    ] + readerAndVoice

    /// All Reader/Voice ids, excluding legacy Pro.
    public static let readerAndVoice: [String] = [
        readerMonthly, readerAnnual, voiceMonthly, voiceAnnual,
        voiceMonthlyMacCatalyst, voiceAnnualMacCatalyst,
        readerMonthlyMacCatalyst, readerAnnualMacCatalyst,
    ]

    public static let iosReaderAndVoiceProductIDs: [String] = [
        readerMonthly, voiceMonthly, readerAnnual, voiceAnnual,
    ]

    public static let macCatalystReaderAndVoiceProductIDs: [String] = [
        readerMonthlyMacCatalyst, voiceMonthlyMacCatalyst,
        readerAnnualMacCatalyst, voiceAnnualMacCatalyst,
    ]

    #if targetEnvironment(macCatalyst)
    public static let currentPlatformProductIDs = macCatalystReaderAndVoiceProductIDs
    #else
    public static let currentPlatformProductIDs = iosReaderAndVoiceProductIDs
    #endif

    public enum Plan: Equatable, Sendable {
        case reader, voice
    }

    public struct Metadata: Equatable, Sendable {
        public let plan: Plan
        public let durationMonths: Int
    }

    public static func metadata(for productID: String) -> Metadata? {
        switch productID {
        case readerMonthly, readerMonthlyMacCatalyst: return .init(plan: .reader, durationMonths: 1)
        case readerAnnual, readerAnnualMacCatalyst: return .init(plan: .reader, durationMonths: 12)
        case voiceMonthly, voiceMonthlyMacCatalyst: return .init(plan: .voice, durationMonths: 1)
        case voiceAnnual, voiceAnnualMacCatalyst: return .init(plan: .voice, durationMonths: 12)
        default: return nil
        }
    }

    /// Explicit current-platform merchandising order for
    /// `SubscriptionStoreView(productIDs:)`.
    public static let currentPlatformPaywallProductIDs: [String] = {
        #if targetEnvironment(macCatalyst)
        [
            readerMonthlyMacCatalyst,
            voiceMonthlyMacCatalyst,
            readerAnnualMacCatalyst,
            voiceAnnualMacCatalyst,
        ]
        #else
        [
            readerMonthly,
            voiceMonthly,
            readerAnnual,
            voiceAnnual,
        ]
        #endif
    }()

    // Kept as a compatibility alias for existing billing callers.
    public static let paywallDisplayOrder = currentPlatformPaywallProductIDs
}
