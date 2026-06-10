import Testing
import Foundation
@testable import RishiBilling
import RishiCore
import RishiAPI

@Suite("RishiBilling package smoke")
struct PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiBilling.version == "0.1.0-scaffold")
    }

    @Test("RishiCore User is reachable from the test target")
    func rishiCoreUserIsReachable() {
        let user = User(
            id: UUID(),
            email: "test@example.com",
            displayName: nil,
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
        #expect(user.hasPro == false)
    }

    @Test("RishiAPI BillingPortalEndpoint is reachable")
    func rishiAPIBillingEndpointIsReachable() {
        let ep = BillingPortalEndpoint()
        #expect(ep.path == "/api/billing/portal")
    }
}
