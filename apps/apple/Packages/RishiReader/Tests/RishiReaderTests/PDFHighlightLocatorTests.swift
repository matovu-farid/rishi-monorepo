import Testing
import Foundation
import CoreGraphics
@testable import RishiReader

@Suite("PDFHighlightLocator")
struct PDFHighlightLocatorTests {

    @Test("Round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let locator = PDFHighlightLocator(
            page: 42,
            rects: [
                CGRect(x: 50, y: 100, width: 200, height: 14),
                CGRect(x: 50, y: 80,  width: 180, height: 14)
            ],
            text: "The quick brown fox"
        )
        let json = try locator.encodedJSONString()
        let decoded = try PDFHighlightLocator.decode(jsonString: json)
        #expect(decoded.page == 42)
        #expect(decoded.rects.count == 2)
        #expect(decoded.rects[0].minX == 50)
        #expect(decoded.rects[0].minY == 100)
        #expect(decoded.rects[0].width == 200)
        #expect(decoded.rects[0].height == 14)
        #expect(decoded.text == "The quick brown fox")
    }

    @Test("Encoded JSON tags format as pdf-v1")
    func encodedJSONTagsFormat() throws {
        let json = try PDFHighlightLocator(page: 1, rects: [], text: "").encodedJSONString()
        #expect(json.contains("\"format\":\"pdf-v1\""))
    }

    @Test("Unknown format throws DecodingError")
    func unknownFormatThrows() {
        let json = "{\"format\":\"epub-v1\",\"page\":1,\"rects\":[],\"text\":\"x\"}"
        #expect(throws: DecodingError.self) {
            _ = try PDFHighlightLocator.decode(jsonString: json)
        }
    }

    @Test("Empty rects round-trips cleanly")
    func emptyRectsRoundTrips() throws {
        let locator = PDFHighlightLocator(page: 0, rects: [], text: "")
        let json = try locator.encodedJSONString()
        let decoded = try PDFHighlightLocator.decode(jsonString: json)
        #expect(decoded.rects.isEmpty)
        #expect(decoded.text == "")
        #expect(decoded.page == 0)
    }

    @Test("Format constant matches schema tag")
    func formatConstantMatchesSchemaTag() {
        #expect(PDFHighlightLocator.format == "pdf-v1")
    }
}
