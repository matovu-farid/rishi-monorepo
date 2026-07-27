@testable import rishi
import Foundation
import Testing

@Suite("StoreKit Config")
struct StoreKitConfigTests {

    @Test("catalog contains every live product and preserves legacy Pro")
    func catalogContainsAllLiveProductIDs() {
        let expected: Set<String> = [
            RishiProductID.proMonthly,
            RishiProductID.proAnnual,
            "rishi.reader.monthly",
            "org.fidexa.rishi.reader.annual",
            "org.fidexa.rishi.voice.monthly",
            "org.fidexa.rishi.voice.annual",
            "org.fidexa.rishi.reader.monthly.macos",
            "org.fidexa.rishi.reader.annual.macos",
            "org.fidexa.rishi.voice.monthly.macos",
            "org.fidexa.rishi.voice.annual.macos",
        ]

        #expect(Set(RishiProductID.all) == expected)
        #expect(RishiProductID.all.count == expected.count)
        #expect(fetchProductIDs() == RishiProductID.currentPlatformProductIDs)
        #expect(EntitlementLevel.initialize(productId: RishiProductID.proMonthly) == .subscribed)
        #expect(EntitlementLevel.initialize(productId: RishiProductID.proAnnual) == .subscribed)
    }

    @Test("iOS and Catalyst product catalogs are disjoint")
    func platformCatalogsAreDisjoint() {
        #expect(Set(RishiProductID.iosReaderAndVoiceProductIDs).isDisjoint(
            with: Set(RishiProductID.macCatalystReaderAndVoiceProductIDs)
        ))
        #expect(RishiProductID.iosReaderAndVoiceProductIDs.count == 4)
        #expect(RishiProductID.macCatalystReaderAndVoiceProductIDs.count == 4)
    }

    @Test("Catalyst products map to the same plans and durations")
    func catalystProductsMatchIOSPlans() {
        #expect(RishiProductID.metadata(for: RishiProductID.voiceMonthly)
                == RishiProductID.metadata(for: RishiProductID.voiceMonthlyMacCatalyst))
        #expect(RishiProductID.metadata(for: RishiProductID.voiceAnnual)
                == RishiProductID.metadata(for: RishiProductID.voiceAnnualMacCatalyst))
        #expect(RishiProductID.metadata(for: RishiProductID.readerMonthly)
                == RishiProductID.metadata(for: RishiProductID.readerMonthlyMacCatalyst))
        #expect(RishiProductID.metadata(for: RishiProductID.readerAnnual)
                == RishiProductID.metadata(for: RishiProductID.readerAnnualMacCatalyst))
    }

    @Test("current catalog is scoped to the compiled Apple target")
    func currentCatalogIsPlatformScoped() {
        #expect(!RishiProductID.currentPlatformProductIDs.contains(RishiProductID.proMonthly))
        #expect(!RishiProductID.currentPlatformProductIDs.contains(RishiProductID.proAnnual))

        #if targetEnvironment(macCatalyst)
        #expect(RishiProductID.currentPlatformProductIDs == RishiProductID.macCatalystReaderAndVoiceProductIDs)
        #else
        #expect(RishiProductID.currentPlatformProductIDs == RishiProductID.iosReaderAndVoiceProductIDs)
        #endif
    }

    @Test("Voice monthly subscription belongs to the expected subscription group")
    func voiceMonthlySubscriptionGroupIdIsStable() throws {
        guard let url = PackageTestResourceBundle.bundle.url(forResource: "Rishi", withExtension: "storekit") else {
            Issue.record("Rishi.storekit missing from test bundle")
            return
        }

        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Rishi.storekit did not decode to a top-level JSON object")
            return
        }
        guard let groups = json["subscriptionGroups"] as? [[String: Any]] else {
            Issue.record("subscriptionGroups missing or not an array")
            return
        }
        guard let group = groups.first(where: { group in
            (group["subscriptions"] as? [[String: Any]])?.contains {
                $0["productID"] as? String == "org.fidexa.rishi.voice.monthly"
            } == true
        }) else {
            Issue.record("subscription group containing org.fidexa.rishi.voice.monthly not found")
            return
        }

        #expect(group["id"] as? String == "22247412")
    }
}
