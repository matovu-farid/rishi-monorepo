import Testing
import Foundation
@testable import RishiReader

@Suite("EPUBHighlightLocator", .serialized)
struct EPUBHighlightLocatorTests {

    @Test("Round-trips lossless")
    func roundTripsLossless() throws {
        let raw = #"{"href":"ch1.xhtml","type":"application/xhtml+xml","text":{"highlight":"down the rabbit hole"}}"#
        let locator = EPUBHighlightLocator(readiumLocator: raw, text: "down the rabbit hole")
        let encoded = try locator.encodedJSONString()
        let decoded = try EPUBHighlightLocator.decode(jsonString: encoded)
        #expect(decoded == locator)
        #expect(decoded.text == "down the rabbit hole")
    }

    @Test("Encoded payload contains format epub-v1 + text")
    func encodedPayloadContainsFormatAndText() throws {
        let locator = EPUBHighlightLocator(readiumLocator: "{}", text: "snippet")
        let encoded = try locator.encodedJSONString()
        #expect(encoded.contains("\"format\":\"epub-v1\""))
        #expect(encoded.contains("\"text\":\"snippet\""))
    }

    @Test("decode rejects mismatched format tag")
    func rejectsMismatchedFormat() {
        let bad = #"{"format":"pdf-v1","readiumLocator":"{}","text":"x"}"#
        #expect(throws: DecodingError.self) {
            try EPUBHighlightLocator.decode(jsonString: bad)
        }
    }
}
