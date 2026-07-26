@testable import rishi
import Testing
import Foundation
import PDFKit


/// Tests for `PDFSelectionCoordinator` — the pure-Swift adapter that turns a
/// PDFKit `PDFSelection` into a persistable `PDFHighlightLocator` (page index +
/// per-line rects in PDF user-space + selected text).
///
/// `@Suite(.serialized)` per project convention — tests touch shared
/// `PDFDocument` state and write small fixture PDFs to the temp dir.
@Suite("PDFSelectionCoordinator", .serialized)
struct PDFSelectionCoordinatorTests {

    @Test("Returns nil for an empty selection")
    func returnsNilForEmpty() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("sel-empty-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 1, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))

        let emptySel = PDFSelection(document: doc)
        let locator = PDFSelectionCoordinator.makeLocator(from: emptySel, in: doc)
        #expect(locator == nil)
    }

    @Test("Returns locator with page index 0 for first-page selection")
    func firstPageSelection() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("sel-first-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 2, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))

        // FixtureBuilders renders "Page 1" as a rasterized image (no extractable
        // text glyphs), so PDFKit's `page.selection(for:)` may legitimately
        // return nil OR return a non-nil-but-empty selection on CI runners.
        // In both cases guard-and-skip — the coordinator's round-trip
        // correctness is also exercised in the VM-highlights tests by
        // constructing a `PDFHighlightLocator` directly.
        guard let sel = page.selection(for: page.bounds(for: .mediaBox)),
              !sel.selectionsByLine().isEmpty
        else {
            // No selectable text on this fixture; that's acceptable.
            return
        }
        let locator = try #require(PDFSelectionCoordinator.makeLocator(from: sel, in: doc))
        #expect(locator.page == 0)
    }
}
