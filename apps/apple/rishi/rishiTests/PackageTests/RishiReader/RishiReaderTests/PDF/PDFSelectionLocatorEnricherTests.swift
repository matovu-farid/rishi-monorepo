@testable import rishi
#if canImport(UIKit)
import Testing
import Foundation
import CoreGraphics
import PDFKit
import ReadiumShared


@Suite("PDFSelectionLocatorEnricher", .serialized)
struct PDFSelectionLocatorEnricherTests {

    private func makePDFLocator(
        page: Int = 2,
        text: String = "selected text"
    ) -> Locator {
        Locator(
            href: RelativeURL(path: "publication.pdf")!,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(page)"]),
            text: Locator.Text(highlight: text)
        )
    }

    @Test("Attaching known rects produces geometry EPUBHighlightLocator can round-trip")
    func attachingRectsRoundTripsThroughEPUBHighlightLocator() throws {
        let base = makePDFLocator(page: 4, text: "lemma")
        let rects = [
            CGRect(x: 50, y: 100, width: 200, height: 14),
            CGRect(x: 50, y: 80, width: 180, height: 14),
        ]

        let enriched = LocatorHighlightGeometry.attaching(rects: rects, to: base)
        let wrapper = try #require(EPUBSelectionCoordinator.makeLocator(fromLocator: enriched))
        let json = try wrapper.encodedJSONString()
        let decoded = try EPUBHighlightLocator.decode(jsonString: json)
        let restored = try #require(decoded.toReadiumLocator())

        #expect(LocatorHighlightGeometry.page(from: restored) == 4)
        let restoredRects = try #require(LocatorHighlightGeometry.rects(from: restored))
        #expect(restoredRects.count == 2)
        #expect(restoredRects[0].width == 200)
        #expect(restoredRects[1].width == 180)
        #expect(decoded.text == "lemma")
    }

    @Test("enriching attaches line rects from a PDFKit selection when available")
    func enrichingAttachesLineRectsFromPDFSelection() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(
            "enrich-\(UUID().uuidString).pdf"
        )
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 1, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        guard let pdfSelection = page.selection(for: page.bounds(for: .mediaBox)),
              !pdfSelection.selectionsByLine().isEmpty
        else {
            // Fixture may be image-only on some runners; geometry attach path
            // is covered by the round-trip test above.
            return
        }

        let base = makePDFLocator(page: 1, text: pdfSelection.string ?? "Page 1")
        let enriched = PDFSelectionLocatorEnricher.enriching(base, with: pdfSelection)
        let rects = try #require(LocatorHighlightGeometry.rects(from: enriched))
        #expect(!rects.isEmpty)
        #expect(LocatorHighlightGeometry.page(from: enriched) == 1)
    }

    @Test("enriching leaves locator unchanged when selection has no pages")
    func enrichingNoOpsForEmptySelection() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(
            "enrich-empty-\(UUID().uuidString).pdf"
        )
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 1, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try #require(PDFDocument(url: url))
        let empty = PDFSelection(document: doc)
        let base = makePDFLocator()
        let result = PDFSelectionLocatorEnricher.enriching(base, with: empty)

        #expect(LocatorHighlightGeometry.rects(from: result) == nil)
        #expect(result.locations.fragments == base.locations.fragments)
        #expect(result.text.highlight == base.text.highlight)
    }

    @Test("resolveRects prefers line rects over whole-selection fallback")
    func resolveRectsPrefersLineRects() {
        let line = [CGRect(x: 1, y: 2, width: 3, height: 4)]
        let whole = [CGRect(x: 10, y: 20, width: 30, height: 40)]
        #expect(PDFSelectionLocatorEnricher.resolveRects(lineRects: line, fallbackRects: whole) == line)
    }

    @Test("resolveRects falls back to whole-selection bounds when line rects empty")
    func resolveRectsFallsBackToWholeSelectionBounds() {
        let whole = [
            CGRect(x: 50, y: 100, width: 200, height: 14),
            CGRect(x: 50, y: 80, width: 180, height: 14),
        ]
        #expect(
            PDFSelectionLocatorEnricher.resolveRects(lineRects: [], fallbackRects: whole) == whole
        )
    }

    @Test("lineRects extracts per-line bounds matching PDFSelectionCoordinator")
    func lineRectsMatchLegacyCoordinatorExtraction() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(
            "enrich-lines-\(UUID().uuidString).pdf"
        )
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 1, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        guard let pdfSelection = page.selection(for: page.bounds(for: .mediaBox)),
              !pdfSelection.selectionsByLine().isEmpty
        else {
            return
        }

        let enricherRects = PDFSelectionLocatorEnricher.lineRects(from: pdfSelection)
        let legacy = try #require(PDFSelectionCoordinator.makeLocator(from: pdfSelection, in: doc))
        #expect(enricherRects.count == legacy.rects.count)
        for (lhs, rhs) in zip(enricherRects, legacy.rects) {
            #expect(lhs.origin == rhs.origin)
            #expect(lhs.size == rhs.size)
        }
    }
}
#endif
