@testable import rishi
import Foundation
import Testing



/// Plan 15-02 — Session.userId becomes `String` to match the production
/// Better Auth + Apple `sub` wire format. These tests pin the new shape
/// and the on-disk Keychain backwards-compat contract (legacy UUID-string
/// blobs decode unchanged into the new `String` field — JSON-level
/// representation is identical, so no migration shim is required).
///
/// Note: the original plan placed this file under
/// `RishiCore/Tests/RishiCoreTests/`. `Session` actually lives in
/// `RishiAuth`, so the tests must too (RishiCore has no dependency on
/// `Session` — only the `UserID` typealias and `User` model). Documented
/// in 15-02-SUMMARY.md as a Rule 3 deviation.
@Suite("Session.userId is String (15-02)")
struct SessionTests {

    @Test func decodesLegacyUUIDStringAsUserIdString() throws {
        let json = """
        {"token":"t","userId":"550e8400-e29b-41d4-a716-446655440000","email":"a@b.c","provider":"apple","issuedAt":0,"expiresAt":null}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        #expect(session.userId == "550e8400-e29b-41d4-a716-446655440000")
    }

    @Test func decodesAppleSubAsUserIdString() throws {
        let json = """
        {"token":"t","userId":"001234.abcdef0123456789.1234","email":"a@b.c","provider":"apple","issuedAt":0,"expiresAt":null}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        #expect(session.userId == "001234.abcdef0123456789.1234")
    }

    @Test func roundTripsArbitraryStringUserId() throws {
        let original = Session(
            token: "t",
            userId: "abc",
            email: nil,
            provider: .apple,
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.userId == "abc")
        // Compile-time witness that userId is `String`, not `UUID`:
        let _: String = decoded.userId
    }
}
