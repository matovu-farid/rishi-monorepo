@testable import rishi
import Testing
import Foundation


@Suite("EPUBPositionLocator", .serialized)
struct EPUBPositionLocatorTests {

    @Test("Round-trips through encodedJSONString → decode")
    func roundTripsThroughString() throws {
        let raw = #"{"href":"chapter1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.42,"totalProgression":0.13,"otherLocations":{"cfi":"epubcfi(/6/4[chapter1]!/4/2/1:0)"}}}"#
        let locator = EPUBPositionLocator(readiumLocator: raw)
        let encoded = try locator.encodedJSONString()
        let decoded = try EPUBPositionLocator.decode(jsonString: encoded)
        #expect(decoded == locator)
        #expect(decoded.readiumLocator == raw)
    }

    @Test("Encoded payload contains format tag epub-v1")
    func encodedPayloadContainsFormatTag() throws {
        let locator = EPUBPositionLocator(readiumLocator: "{}")
        let encoded = try locator.encodedJSONString()
        #expect(encoded.contains("\"format\":\"epub-v1\""))
    }

    @Test("decode rejects mismatched format tag")
    func rejectsMismatchedFormat() {
        let bad = #"{"format":"pdf-v1","readiumLocator":"{}"}"#
        #expect(throws: DecodingError.self) {
            try EPUBPositionLocator.decode(jsonString: bad)
        }
    }

    @Test("Format tag is exactly epub-v1")
    func formatTagIsEpubV1() {
        #expect(EPUBPositionLocator.format == "epub-v1")
    }
}
