import Testing
import Foundation
import CoreGraphics
import ReadiumShared
@testable import RishiReader

/// PDF highlight geometry lives on a Readium ``Locator`` so EPUB and PDF can
/// share ``EPUBHighlightLocator`` (format `epub-v1`). Page comes from the
/// existing `page=N` fragment; rects are stored under `otherLocations`.
@Suite("LocatorHighlightGeometry", .serialized)
struct LocatorHighlightGeometryTests {

    private func makePDFLocator(
        page: Int = 3,
        text: String = "The quick brown fox"
    ) -> Locator {
        Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(page)"]),
            text: Locator.Text(highlight: text)
        )
    }

    @Test("Attaches rects under otherLocations rects key as [x0,y0,x1,y1]")
    func attachesRectsUnderOtherLocationsKey() throws {
        let base = makePDFLocator(page: 42)
        let rects = [
            CGRect(x: 50, y: 100, width: 200, height: 14),
            CGRect(x: 50, y: 80, width: 180, height: 14),
        ]

        let enriched = LocatorHighlightGeometry.attaching(rects: rects, to: base)

        #expect(enriched.locations.page == 42)
        #expect(enriched.locations.fragments == ["page=42"])
        #expect(enriched.text.highlight == "The quick brown fox")

        let raw = try #require(enriched.locations.otherLocations[LocatorHighlightGeometry.rectsKey])
        let arrays = try #require(raw.array)
        #expect(arrays.count == 2)

        let first = try #require(arrays[0].array)
        #expect(first.map(\.double) == [50, 100, 250, 114])
        let second = try #require(arrays[1].array)
        #expect(second.map(\.double) == [50, 80, 230, 94])
    }

    @Test("Reads attached rects back as CGRects")
    func readsAttachedRects() {
        let base = makePDFLocator()
        let rects = [
            CGRect(x: 50, y: 100, width: 200, height: 14),
            CGRect(x: 10.5, y: 20.25, width: 30.5, height: 12),
        ]
        let enriched = LocatorHighlightGeometry.attaching(rects: rects, to: base)
        let decoded = LocatorHighlightGeometry.rects(from: enriched)

        #expect(decoded?.count == 2)
        #expect(decoded?[0].minX == 50)
        #expect(decoded?[0].minY == 100)
        #expect(decoded?[0].width == 200)
        #expect(decoded?[0].height == 14)
        #expect(decoded?[1].minX == 10.5)
        #expect(decoded?[1].minY == 20.25)
        #expect(decoded?[1].width == 30.5)
        #expect(decoded?[1].height == 12)
    }

    @Test("Round-trips through Locator.jsonString and EPUBHighlightLocator")
    func roundTripsThroughLocatorJSONAndEPUBHighlightLocator() throws {
        let base = makePDFLocator(page: 7, text: "selected")
        let rects = [CGRect(x: 1, y: 2, width: 3, height: 4)]
        let enriched = LocatorHighlightGeometry.attaching(rects: rects, to: base)

        let wrapper = EPUBHighlightLocator(locator: enriched)
        let encoded = try wrapper.encodedJSONString()
        let decodedWrapper = try EPUBHighlightLocator.decode(jsonString: encoded)
        let restored = try #require(decodedWrapper.toReadiumLocator())

        #expect(LocatorHighlightGeometry.page(from: restored) == 7)
        let restoredRects = try #require(LocatorHighlightGeometry.rects(from: restored))
        #expect(restoredRects.count == 1)
        #expect(restoredRects[0].minX == 1)
        #expect(restoredRects[0].minY == 2)
        #expect(restoredRects[0].maxX == 4)
        #expect(restoredRects[0].maxY == 6)
        #expect(decodedWrapper.text == "selected")
    }

    @Test("Empty rects round-trip and preserve page fragment")
    func emptyRectsRoundTrip() throws {
        let base = makePDFLocator(page: 1)
        let enriched = LocatorHighlightGeometry.attaching(rects: [], to: base)
        #expect(LocatorHighlightGeometry.rects(from: enriched) == [])
        #expect(LocatorHighlightGeometry.page(from: enriched) == 1)

        let json = try enriched.jsonString()
        let restored = try Locator(jsonString: json)
        #expect(LocatorHighlightGeometry.rects(from: restored) == [])
        #expect(LocatorHighlightGeometry.page(from: restored) == 1)
    }

    @Test("Missing rects key returns nil")
    func missingRectsKeyReturnsNil() {
        let base = makePDFLocator()
        #expect(LocatorHighlightGeometry.rects(from: base) == nil)
    }

    @Test("page(from:) reads page=N fragment")
    func pageFromFragment() {
        let locator = makePDFLocator(page: 9)
        #expect(LocatorHighlightGeometry.page(from: locator) == 9)
        #expect(LocatorHighlightGeometry.page(from: makePDFLocator(page: 1)) == 1)
    }

    @Test("Rects key constant is rects")
    func rectsKeyConstant() {
        #expect(LocatorHighlightGeometry.rectsKey == "rects")
    }
}
