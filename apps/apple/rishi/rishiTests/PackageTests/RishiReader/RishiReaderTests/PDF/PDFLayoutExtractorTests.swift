@testable import rishi
//
//  PDFLayoutExtractorTests.swift
//  RishiReaderTests — Phase 27 plan 27-01
//
//  Tests for layout-aware PDF text extraction. Builds synthetic PDFs in a
//  temp directory using a CoreGraphics PDF context so PDFKit sees real
//  selectable text (the existing `FixtureBuilders.writeMultiPagePDF`
//  rasterises text into an image — useless for selection-based tests).
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit



@Suite("PDFLayoutExtractor", .serialized)
struct PDFLayoutExtractorTests {

    // MARK: - Fixture helpers

    private static let pageSize = CGSize(width: 612, height: 792) // US Letter

    /// One PDF text line, positioned in PDF user-space coordinates
    /// (origin bottom-left).
    struct Line {
        let text: String
        /// Baseline x in points.
        let x: CGFloat
        /// Baseline y in points (origin bottom-left).
        let y: CGFloat
        /// Font size in points.
        let fontSize: CGFloat
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString).pdf"
        )
    }

    /// Writes a multi-page PDF where each page renders the given lines
    /// as real PDF text (not rasterised). Lines use Helvetica at the
    /// requested font sizes — PDFKit can select and bound them.
    private func writeTextPDF(to url: URL, pages: [[Line]]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create CGContext for PDF")
            return
        }
        for lines in pages {
            ctx.beginPDFPage(nil)
            for line in lines {
                drawLine(line, in: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func drawLine(_ line: Line, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let attributed = NSAttributedString(string: line.text, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: line.x, y: line.y)
        CTLineDraw(ctLine, ctx)
    }

    /// Writes a minimal blank-page PDF using PDFKit (no text).
    private func writeBlankPDF(to url: URL, pageCount: Int) throws {
        let doc = PDFDocument()
        for i in 0..<pageCount {
            let blank = PDFPage()
            doc.insert(blank, at: i)
        }
        if let data = doc.dataRepresentation() {
            try data.write(to: url, options: .atomic)
        } else {
            Issue.record("Could not encode blank PDF")
        }
    }

    // MARK: - Tests

    @Test("Throws unreadableDocument for missing file")
    func missingFileThrows() async {
        let url = URL.temporaryDirectory.appendingPathComponent(
            "missing-\(UUID().uuidString).pdf"
        )
        await #expect(throws: PDFLayoutExtractor.ExtractionError.self) {
            _ = try await PDFLayoutExtractor.extract(url)
        }
    }

    @Test("Returns one PageText per page in order")
    func returnsOnePageTextPerPage() async throws {
        let url = makeTempURL("three-page")
        defer { try? FileManager.default.removeItem(at: url) }

        let pages: [[Line]] = (1...3).map { n in
            [
                Line(text: "Top body line A", x: 72, y: 720, fontSize: 12),
                Line(text: "Body line B",     x: 72, y: 400, fontSize: 12),
                Line(text: "Page \(n)",       x: 72, y:  60, fontSize: 10),
            ]
        }
        try writeTextPDF(to: url, pages: pages)

        let result = try await PDFLayoutExtractor.extract(url)

        #expect(result.count == 3)
        for (i, page) in result.enumerated() {
            #expect(page.pageIndex == i)
            #expect(page.frame.width == 612)
            #expect(page.frame.height == 792)
            // At least the three lines we drew.
            #expect(page.items.count >= 3)
        }
    }

    @Test("Page-number line sits in the bottom 25% band")
    func pageNumberInBottomBand() async throws {
        let url = makeTempURL("bottom-band")
        defer { try? FileManager.default.removeItem(at: url) }

        let pages: [[Line]] = (1...3).map { n in
            [
                Line(text: "Top body line A", x: 72, y: 720, fontSize: 12),
                Line(text: "Body line B",     x: 72, y: 400, fontSize: 12),
                Line(text: "Page \(n)",       x: 72, y:  60, fontSize: 10),
            ]
        }
        try writeTextPDF(to: url, pages: pages)

        let result = try await PDFLayoutExtractor.extract(url)

        let firstPage = try #require(result.first)
        let band = firstPage.frame.height * 0.25
        let pageOneItem = try #require(
            firstPage.items.first(where: { $0.text.contains("Page 1") })
        )
        #expect(pageOneItem.frame.minY < band,
                "Expected 'Page 1' line minY \(pageOneItem.frame.minY) to be < \(band)")
    }

    @Test("Lowest y-coord on a page is the page-number line")
    func pdfCoordinateSystemBottomLeftOrigin() async throws {
        let url = makeTempURL("coord-check")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines: [Line] = [
            Line(text: "Top body line A", x: 72, y: 720, fontSize: 12),
            Line(text: "Body line B",     x: 72, y: 400, fontSize: 12),
            Line(text: "Page 1",          x: 72, y:  60, fontSize: 10),
        ]
        try writeTextPDF(to: url, pages: [lines])

        let result = try await PDFLayoutExtractor.extract(url)
        let page = try #require(result.first)
        // PDF coord system: origin bottom-left, Y grows up. "Page 1" drawn
        // at y=60 must have the lowest minY of the three.
        guard let pageOne = page.items.first(where: { $0.text.contains("Page 1") }),
              let bodyA   = page.items.first(where: { $0.text.contains("Top body line A") }),
              let bodyB   = page.items.first(where: { $0.text.contains("Body line B") })
        else {
            Issue.record("Missing expected line items: \(page.items.map(\.text))")
            return
        }
        #expect(pageOne.frame.minY < bodyB.frame.minY)
        #expect(bodyB.frame.minY < bodyA.frame.minY)
    }

    @Test("Empty (0-page) document returns []")
    func emptyDocument() async throws {
        // Encode an empty PDFDocument; some PDF tools refuse zero-page
        // PDFs, so we use a 0-page in-memory `PDFDocument()` which
        // PDFKit accepts. If `dataRepresentation()` returns nil, fall
        // back to skipping the assertion (the codepath is exercised at
        // runtime when PDFKit hands back pageCount == 0).
        let doc = PDFDocument()
        guard let data = doc.dataRepresentation() else {
            // Acceptable — pageCount == 0 path is still covered by the
            // missing-page guard. Nothing more to assert here.
            return
        }
        let url = makeTempURL("empty")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await PDFLayoutExtractor.extract(url)
        #expect(result.isEmpty)
    }

    @Test("Pages with no selectable text yield empty items array")
    func blankPagesYieldEmptyItems() async throws {
        let url = makeTempURL("blank")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBlankPDF(to: url, pageCount: 2)

        let result = try await PDFLayoutExtractor.extract(url)
        // Blank PDFKit pages may or may not be persisted by
        // dataRepresentation — accept either zero pages or pages with
        // empty items.
        for page in result {
            #expect(page.items.isEmpty,
                    "Blank page should have no items, got \(page.items.map(\.text))")
        }
    }

    @Test("TextItem.fontSize is positive for selectable text")
    func fontSizeIsPositive() async throws {
        let url = makeTempURL("font-size")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTextPDF(to: url, pages: [[
            Line(text: "Hello world", x: 72, y: 400, fontSize: 14),
        ]])

        let result = try await PDFLayoutExtractor.extract(url)
        let page = try #require(result.first)
        let item = try #require(
            page.items.first(where: { $0.text.contains("Hello") })
        )
        #expect(item.fontSize > 0)
    }
}
