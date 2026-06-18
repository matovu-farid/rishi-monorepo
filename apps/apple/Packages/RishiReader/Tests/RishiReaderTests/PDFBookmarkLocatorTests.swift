import Testing
import Foundation
@testable import RishiReader

@Suite("PDFBookmarkLocator")
struct PDFBookmarkLocatorTests {

    @Test("Round-trips page and snippet through JSON")
    func roundTripsThroughJSON() throws {
        let locator = PDFBookmarkLocator(page: 42, snippet: "The quick brown fox")
        let json = try locator.encodedJSONString()
        let decoded = try PDFBookmarkLocator.decode(jsonString: json)
        #expect(decoded.page == 42)
        #expect(decoded.snippet == "The quick brown fox")
        #expect(decoded == locator)
    }

    @Test("Round-trips with nil snippet")
    func roundTripsWithNilSnippet() throws {
        let locator = PDFBookmarkLocator(page: 0)
        let json = try locator.encodedJSONString()
        let decoded = try PDFBookmarkLocator.decode(jsonString: json)
        #expect(decoded.page == 0)
        #expect(decoded.snippet == nil)
        #expect(decoded == locator)
    }

    @Test("Encoded JSON tags format as pdf-bmk-v1")
    func encodedJSONTagsFormat() throws {
        let json = try PDFBookmarkLocator(page: 1).encodedJSONString()
        #expect(json.contains("\"format\":\"pdf-bmk-v1\""))
    }

    @Test("Rejects the highlight format tag pdf-v1")
    func rejectsHighlightFormatTag() {
        let bad = "{\"format\":\"pdf-v1\",\"page\":1,\"rects\":[],\"text\":\"x\"}"
        #expect(throws: DecodingError.self) {
            _ = try PDFBookmarkLocator.decode(jsonString: bad)
        }
    }

    @Test("Format constant matches schema tag")
    func formatConstantMatchesSchemaTag() {
        #expect(PDFBookmarkLocator.format == "pdf-bmk-v1")
    }
}
