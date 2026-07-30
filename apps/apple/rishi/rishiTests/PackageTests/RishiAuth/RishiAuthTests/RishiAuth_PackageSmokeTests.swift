@testable import rishi
import Foundation
import Testing



@Suite("RishiAuth package smoke")
struct RishiAuth_PackageSmokeTests {

    @Test func apiVersionIsScaffoldMarker() {
        #expect(RishiAuth.apiVersion == "0.1.0-scaffold")
    }

    @Test func sessionRoundTripsThroughJSON() throws {
        // Plan 15-02: Session.userId is `String` (Better Auth `user.id`).
        let userId = "001234.abcdef0123456789.1234"
        let original = Session(
            token: "tok-xyz",
            userId: userId,
            email: "user@privaterelay.appleid.com",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Session.self, from: data)

        #expect(decoded == original)
        #expect(decoded.userId == userId)
    }

    @Test func sessionWithNilEmailEncodes() throws {
        // PITFALLS.md Pitfall 10: subsequent SIWA sign-ins return no email.
        let session = Session(
            token: "tok-1",
            userId: "001234.abcdef0123456789.1234",
            email: nil
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.email == nil)
        #expect(decoded.token == "tok-1")
    }

}
