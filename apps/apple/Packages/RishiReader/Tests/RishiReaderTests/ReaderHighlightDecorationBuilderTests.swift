#if canImport(UIKit)
import Testing
import Foundation
import CoreGraphics
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiCore
@testable import RishiReader

@Suite("ReaderHighlightDecorationBuilder", .serialized)
struct ReaderHighlightDecorationBuilderTests {

    private func makeHighlight(
        text: String,
        color: HighlightColor = .yellow,
        page: Int? = nil,
        rects: [CGRect] = []
    ) throws -> Highlight {
        var locator = Locator(
            href: RelativeURL(path: page == nil ? "chapter1.xhtml" : "publication.pdf")!,
            mediaType: page == nil ? .xhtml : .pdf,
            locations: Locator.Locations(
                fragments: page.map { ["page=\($0)"] } ?? [],
                progression: page == nil ? 0.25 : nil
            ),
            text: Locator.Text(highlight: text)
        )
        if !rects.isEmpty {
            locator = LocatorHighlightGeometry.attaching(rects: rects, to: locator)
        }
        let wrapper = EPUBHighlightLocator(locator: locator)
        let json = try wrapper.encodedJSONString()
        return Highlight(
            bookId: UUID(),
            locatorStart: json,
            locatorEnd: json,
            color: color,
            text: text
        )
    }

    @Test("Group name is rishi-highlights")
    func groupNameMatchesContract() {
        #expect(ReaderHighlightDecorationBuilder.groupName == "rishi-highlights")
        #expect(ReaderHighlightDecorationBuilder.groupName == EPUBDecorationApplier.groupName)
    }

    @Test("Builds one decoration per valid highlight with matching id and locator text")
    func buildsDecorationsFromHighlights() throws {
        let yellow = try makeHighlight(text: "Alice", color: .yellow)
        let pink = try makeHighlight(text: "Wonderland", color: .pink)

        let decorations = ReaderHighlightDecorationBuilder.make(from: [yellow, pink])

        #expect(decorations.count == 2)
        #expect(decorations[0].id == yellow.id.uuidString)
        #expect(decorations[1].id == pink.id.uuidString)
        #expect(decorations[0].locator.text.highlight == "Alice")
        #expect(decorations[1].locator.text.highlight == "Wonderland")

        // Tint opacity is applied via uiColor(for:) — assert that helper directly.
        var alpha: CGFloat = 0
        ReaderHighlightDecorationBuilder.uiColor(for: .yellow)
            .getRed(nil, green: nil, blue: nil, alpha: &alpha)
        #expect(abs(Double(alpha) - HighlightColor.yellow.pageOverlayOpacity) < 0.001)
    }

    @Test("Preserves PDF page and rects on the decoration locator")
    func preservesPDFGeometry() throws {
        let rects = [CGRect(x: 10, y: 20, width: 100, height: 12)]
        let highlight = try makeHighlight(
            text: "proof",
            color: .green,
            page: 3,
            rects: rects
        )

        let decorations = ReaderHighlightDecorationBuilder.make(from: [highlight])
        let decoration = try #require(decorations.first)

        #expect(LocatorHighlightGeometry.page(from: decoration.locator) == 3)
        let decoded = try #require(LocatorHighlightGeometry.rects(from: decoration.locator))
        #expect(decoded.count == 1)
        #expect(decoded[0].minX == 10)
        #expect(decoded[0].minY == 20)
        #expect(decoded[0].width == 100)
        #expect(decoded[0].height == 12)
    }

    @Test("Skips malformed locatorStart payloads")
    func skipsMalformedRows() {
        let bad = Highlight(
            bookId: UUID(),
            locatorStart: "not-json",
            locatorEnd: "not-json",
            color: .blue,
            text: "x"
        )
        #expect(ReaderHighlightDecorationBuilder.make(from: [bad]).isEmpty)
    }

    @Test("Builds decoration from legacy pdf-v1 locator with 0-based page")
    func buildsFromLegacyPDFHighlightLocator() throws {
        let rects = [CGRect(x: 50, y: 100, width: 200, height: 14)]
        let pdfLocator = PDFHighlightLocator(page: 0, rects: rects, text: "legacy")
        let json = try pdfLocator.encodedJSONString()
        let highlight = Highlight(
            bookId: UUID(),
            locatorStart: json,
            locatorEnd: json,
            color: .yellow,
            text: "legacy"
        )

        let decorations = ReaderHighlightDecorationBuilder.make(from: [highlight])
        let decoration = try #require(decorations.first)

        #expect(decoration.id == highlight.id.uuidString)
        #expect(decoration.locator.text.highlight == "legacy")
        // pdf-v1 page is 0-based; Readium fragment is 1-based.
        #expect(LocatorHighlightGeometry.page(from: decoration.locator) == 1)
        let decoded = try #require(LocatorHighlightGeometry.rects(from: decoration.locator))
        #expect(decoded.count == 1)
        #expect(decoded[0] == rects[0])

        let specs = PDFDecorationAnnotator.specs(from: [decoration], in: "rishi-highlights")
        #expect(specs.count == 1)
        #expect(specs[0].pageIndex == 0)
        #expect(specs[0].bounds == rects[0])
    }
}
#endif
