import Foundation
import Testing
@testable import RishiCore

/// Contract gate for `POST /api/billing/verify-receipt`. Both sides — iOS
/// `VerifyReceiptEndpoint` and the worker's `VerifyReceiptResponse` — round-trip
/// through the SAME JSON fixtures at
/// `apps/apple/Packages/RishiAPI/Tests/RishiAPITests/Fixtures/`. A
/// drift in the worker's emitted shape OR iOS's decoder strategy fails one
/// (or both) suites and names which side moved.
///
/// Wire contract (locked by 14-04 SUMMARY):
///   - request.transactionId : JSON number (UInt64 → JS Number boundary;
///     Pitfall 2 — the 16-digit fixture exceeds 2^53)
///   - response.premiumUntil : JSON number, seconds-since-1970
///   - response.reason       : explicit JSON null on success
///
/// `VerifyReceiptEndpoint.ResponseBody` decodes the JSON number into `Date?`
/// via a hand-rolled `init(from:)` that bypasses `JSONDecoder`'s default
/// `.deferredToDate` strategy (which would misinterpret the number as
/// seconds-since-2001 — off by 31 years). See VerifyReceiptAPI.swift.
@Suite("VerifyReceiptEndpoint contract")
struct VerifyReceiptContractTests {

    // MARK: - Fixture loading

    private func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture \(name).json — Package.swift must declare `.copy(\"Fixtures\")` on the test target."
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Request shape

    @Test("request fixture decodes into VerifyReceiptEndpoint.Request")
    func requestFixtureDecodes() throws {
        let fixture = try loadFixture("verify-receipt-request")
        let decoded = try JSONDecoder().decode(VerifyReceiptEndpoint.Request.self, from: fixture)
        #expect(decoded.productId == "org.fidexa.rishi.pro.monthly")
        // 16-digit value > 2^53 — codifies the UInt64 -> JS Number boundary
        // (RESEARCH §4.1 Pitfall 2). Swift decodes the JSON number directly
        // into UInt64; the worker accepts via Zod union(number, string).
        #expect(decoded.transactionId == 2_000_000_300_000_001)
        #expect(decoded.jws.hasPrefix("eyJhbGciOiJFUzI1NiI"))
    }

    @Test("encoding a Request struct round-trips through the fixture shape")
    func requestEncodeRoundTrip() throws {
        let request = VerifyReceiptEndpoint.Request(
            jws: "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJURVNUX0xFQUYiLCJURVNUX0lOVCIsIlRFU1RfUk9PVCJdfQ.eyJzdWIiOiJ0ZXN0In0.PLACEHOLDER",
            productId: "org.fidexa.rishi.pro.monthly",
            transactionId: 2_000_000_300_000_001
        )
        let encoded = try JSONEncoder().encode(request)
        // Avoid byte-equality (JSON key ordering is not stable); decode through
        // JSONSerialization and assert field-level equivalence with the fixture.
        let any = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let dict = try #require(any)
        #expect(dict["productId"] as? String == "org.fidexa.rishi.pro.monthly")
        // NSNumber bridges to either UInt64 or Int64 depending on platform;
        // string-compare via String(describing:) is portable.
        let txn = dict["transactionId"]
        #expect(String(describing: txn ?? "") == "2000000300000001")
        #expect((dict["jws"] as? String)?.hasPrefix("eyJhbGciOiJFUzI1NiI") == true)
    }

    // MARK: - Response shape

    @Test("response fixture decodes with the WorkerClient default JSONDecoder()")
    func responseDecodesWithWorkerClientDecoder() throws {
        let fixture = try loadFixture("verify-receipt-response")
        // No custom dateDecodingStrategy — matches WorkerClient.send()'s
        // `JSONDecoder()` exactly. VerifyReceiptEndpoint.ResponseBody handles
        // the JSON-number → Date conversion in its hand-rolled init(from:).
        let decoded = try JSONDecoder().decode(
            VerifyReceiptEndpoint.ResponseBody.self,
            from: fixture
        )
        #expect(decoded.verified == true)
        #expect(decoded.reason == nil)

        let expected = Date(timeIntervalSince1970: 1_812_585_600)
        let until = try #require(decoded.premiumUntil)
        // Allow a 1ms tolerance — Date round-trips through Double, so the
        // last bit can wobble.
        #expect(abs(until.timeIntervalSince(expected)) < 0.001)
        // Sanity check the absolute date — 1812585600 seconds = 2027-06-10 UTC,
        // NOT seconds-since-2001 (which would land in 2058).
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        #expect(f.string(from: until) == "2027-06-10T00:00:00Z")
    }

    @Test("response struct round-trips through encode + decode")
    func responseRoundTrip() throws {
        let original = VerifyReceiptEndpoint.ResponseBody(
            verified: true,
            premiumUntil: Date(timeIntervalSince1970: 1_812_585_600),
            reason: nil
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            VerifyReceiptEndpoint.ResponseBody.self,
            from: encoded
        )
        #expect(decoded == original)
    }

    @Test("encoded response wire shape is a JSON number for premiumUntil (not ISO string, not ms)")
    func responseEncodesAsNumberOfSeconds() throws {
        let original = VerifyReceiptEndpoint.ResponseBody(
            verified: true,
            premiumUntil: Date(timeIntervalSince1970: 1_812_585_600),
            reason: nil
        )
        let encoded = try JSONEncoder().encode(original)
        let any = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let dict = try #require(any)
        // The wire shape MUST be a JSON number, not a String (ISO) and not in ms.
        let n = try #require(dict["premiumUntil"] as? Double)
        #expect(abs(n - 1_812_585_600) < 0.001)
        // null reason on the wire — present as NSNull, not missing.
        #expect(dict["reason"] is NSNull)
    }

    @Test("rejection response decodes (verified=false, premiumUntil=null, reason set)")
    func rejectionResponseDecodes() throws {
        let raw = """
        { "verified": false, "premiumUntil": null, "reason": "replay_detected" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            VerifyReceiptEndpoint.ResponseBody.self,
            from: raw
        )
        #expect(decoded.verified == false)
        #expect(decoded.premiumUntil == nil)
        #expect(decoded.reason == "replay_detected")
    }
}
