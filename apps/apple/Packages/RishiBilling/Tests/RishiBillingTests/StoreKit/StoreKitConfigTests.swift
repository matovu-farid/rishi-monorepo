import Foundation
import Testing

@Suite("StoreKit Config")
struct StoreKitConfigTests {

    @Test("Voice monthly subscription belongs to the expected subscription group")
    func voiceMonthlySubscriptionGroupIdIsStable() throws {
        guard let url = Bundle.module.url(forResource: "Rishi", withExtension: "storekit") else {
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
