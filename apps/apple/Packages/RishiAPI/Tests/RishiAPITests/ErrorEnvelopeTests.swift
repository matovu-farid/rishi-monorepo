import Foundation
import Testing
@testable import RishiCore

@Suite("ErrorEnvelope decoding")
struct ErrorEnvelopeTests {

    @Test func decodesFullEnvelope() throws {
        let json = #"""
        {"error":{"code":"forbidden","message":"Pro subscription required.","details":{"reason":"plan_required"}}}
        """#
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(json.utf8))
        #expect(env.code == "forbidden")
        #expect(env.message == "Pro subscription required.")
        #expect(env.details?["reason"] == "plan_required")
    }

    @Test func decodesEnvelopeWithoutDetails() throws {
        let json = #"""
        {"error":{"code":"not_found","message":"Book not found."}}
        """#
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(json.utf8))
        #expect(env.code == "not_found")
        #expect(env.message == "Book not found.")
        #expect(env.details == nil)
    }

    @Test func rejectsMissingErrorKey() {
        let json = #"""
        {"code":"forbidden","message":"x"}
        """#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(json.utf8))
        }
    }

    @Test func staticTokenProviderReturnsStoredValue() async {
        let p1 = StaticTokenProvider("abc")
        let p2 = StaticTokenProvider(nil)
        #expect(await p1.token() == "abc")
        #expect(await p2.token() == nil)
    }
}
