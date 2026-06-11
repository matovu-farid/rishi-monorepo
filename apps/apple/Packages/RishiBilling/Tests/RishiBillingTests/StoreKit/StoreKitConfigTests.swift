import Foundation
import Testing

@Suite("StoreKit Config")
struct StoreKitConfigTests {

    private func loadJSON() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "Rishi", withExtension: "storekit") else {
            Issue.record("Rishi.storekit not found in test bundle")
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Rishi.storekit did not decode to a top-level JSON object")
            return [:]
        }
        return json
    }

    private func subscriptionProducts() throws -> [[String: Any]] {
        let json = try loadJSON()
        guard let groups = json["subscriptionGroups"] as? [[String: Any]] else {
            Issue.record("subscriptionGroups missing or not an array")
            return []
        }
        guard let first = groups.first,
              let subs = first["subscriptions"] as? [[String: Any]] else {
            Issue.record("first subscriptionGroup missing subscriptions array")
            return []
        }
        return subs
    }

    @Test("Rishi.storekit exists in the test bundle")
    func testFileExistsInTestBundle() throws {
        let url = Bundle.module.url(forResource: "Rishi", withExtension: "storekit")
        #expect(url != nil, "Rishi.storekit was not copied into the test bundle")
    }

    @Test("Storekit declares exactly the two Rishi Pro product IDs")
    func testProductIdsPresent() throws {
        let subs = try subscriptionProducts()
        let ids = Set(subs.compactMap { $0["productID"] as? String })
        let expected: Set<String> = [
            "org.fidexa.rishi.pro.monthly",
            "org.fidexa.rishi.pro.annual",
        ]
        #expect(ids == expected, "subscription productIDs were \(ids); expected \(expected)")
    }

    @Test("Both subscriptions have a 7-day free introductory offer")
    func testIntroOfferPresent() throws {
        let subs = try subscriptionProducts()
        #expect(subs.count == 2, "expected 2 subscriptions, found \(subs.count)")
        for sub in subs {
            guard let intro = sub["introductoryOffer"] as? [String: Any] else {
                Issue.record("introductoryOffer missing on product \(sub["productID"] ?? "?")")
                continue
            }
            #expect(intro["paymentMode"] as? String == "free")
            #expect(intro["subscriptionPeriod"] as? String == "P1W")
            let count = intro["numberOfPeriods"]
            if let i = count as? Int { #expect(i == 1) }
            else if let n = count as? NSNumber { #expect(n.intValue == 1) }
            else { Issue.record("numberOfPeriods missing/invalid on \(sub["productID"] ?? "?")") }
        }
    }

    @Test("Monthly and annual recurring periods are P1M and P1Y")
    func testRecurringPeriods() throws {
        let subs = try subscriptionProducts()
        var byId: [String: [String: Any]] = [:]
        for sub in subs {
            if let id = sub["productID"] as? String { byId[id] = sub }
        }
        #expect(byId["org.fidexa.rishi.pro.monthly"]?["recurringSubscriptionPeriod"] as? String == "P1M")
        #expect(byId["org.fidexa.rishi.pro.annual"]?["recurringSubscriptionPeriod"] as? String == "P1Y")
    }

    @Test("Exactly one subscription group named Rishi Pro")
    func testSubscriptionGroup() throws {
        let json = try loadJSON()
        let groups = json["subscriptionGroups"] as? [[String: Any]] ?? []
        #expect(groups.count == 1)
        let first = groups.first ?? [:]
        #expect(first["id"] as? String == "rishi-pro-group")
        #expect(first["name"] as? String == "Rishi Pro")
    }

    @Test("_failTransactionsEnabled is false")
    func testNoFailTransactions() throws {
        let json = try loadJSON()
        guard let settings = json["settings"] as? [String: Any] else {
            Issue.record("settings missing")
            return
        }
        if let b = settings["_failTransactionsEnabled"] as? Bool {
            #expect(b == false)
        } else if let n = settings["_failTransactionsEnabled"] as? NSNumber {
            #expect(n.boolValue == false)
        } else {
            Issue.record("_failTransactionsEnabled missing or wrong type")
        }
    }
}
