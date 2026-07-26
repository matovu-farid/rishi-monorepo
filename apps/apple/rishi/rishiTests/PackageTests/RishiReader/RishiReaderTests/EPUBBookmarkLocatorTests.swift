@testable import rishi
import Testing
import Foundation


@Suite("EPUBBookmarkLocator", .serialized)
struct EPUBBookmarkLocatorTests {

    @Test("Round-trips through encodedJSONString → decode")
    func roundTripsThroughString() throws {
        let raw = #"{"href":"chapter1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.42,"position":12}}"#
        let locator = EPUBBookmarkLocator(readiumLocator: raw)
        let encoded = try locator.encodedJSONString()
        let decoded = try EPUBBookmarkLocator.decode(jsonString: encoded)
        #expect(decoded == locator)
        #expect(decoded.readiumLocator == raw)
    }

    @Test("Encoded payload contains format tag epub-bmk-v1")
    func encodedPayloadContainsFormatTag() throws {
        let locator = EPUBBookmarkLocator(readiumLocator: "{}")
        let encoded = try locator.encodedJSONString()
        #expect(encoded.contains("\"format\":\"epub-bmk-v1\""))
    }

    @Test("decode rejects the position/highlight format tag epub-v1")
    func rejectsMismatchedFormat() {
        let bad = #"{"format":"epub-v1","readiumLocator":"{}"}"#
        #expect(throws: DecodingError.self) {
            try EPUBBookmarkLocator.decode(jsonString: bad)
        }
    }

    @Test("Format tag is exactly epub-bmk-v1")
    func formatTagIsEpubBmkV1() {
        #expect(EPUBBookmarkLocator.format == "epub-bmk-v1")
    }
}
