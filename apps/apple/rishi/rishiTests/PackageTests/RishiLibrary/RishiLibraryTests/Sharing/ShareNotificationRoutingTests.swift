import Testing

@testable import rishi

@Suite("Share notification routing")
struct ShareNotificationRoutingTests {
    @Test("recognizes a share-created APNs payload")
    func recognizesShareCreatedPayload() {
        #expect(ShareNotificationRouting.isShareCreated(userInfo: [
            "rishi": ["kind": "share.created", "package_id": "package-1"]
        ]))
        #expect(!ShareNotificationRouting.isShareCreated(userInfo: [
            "rishi": ["kind": "entitlement.changed"]
        ]))
    }
}
