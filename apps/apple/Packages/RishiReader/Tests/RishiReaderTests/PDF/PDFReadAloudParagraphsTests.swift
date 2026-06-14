//
//  PDFReadAloudParagraphsTests.swift
//  RishiReaderTests
//
//  Integration coverage for layout-aware PDF read-aloud paragraph
//  extraction: `selectionsByLine()` geometry → `PdfParagraphGrouper`. Proves
//  the pipeline recovers paragraph boundaries from line spacing so a page no
//  longer collapses into one TTS chunk.
//
//  Builds synthetic PDFs with a CoreGraphics PDF context (real selectable
//  text), mirroring PDFLayoutExtractorTests.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
import RishiReader

@Suite("PDFReadAloudParagraphs", .serialized)
struct PDFReadAloudParagraphsTests {

    private static let pageSize = CGSize(width: 612, height: 792)

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    private func writeTextPDF(to url: URL, lines: [Line]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create CGContext for PDF")
            return
        }
        ctx.beginPDFPage(nil)
        for line in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil)
            let attributed = NSAttributedString(
                string: line.text,
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: line.x, y: line.y)
            CTLineDraw(ctLine, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func firstPage(of url: URL) throws -> PDFPage {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: 0))
    }

    @Test("Visually separated paragraphs extract as distinct blocks")
    func separatedParagraphsSplit() throws {
        let url = makeTempURL("two-paras")
        defer { try? FileManager.default.removeItem(at: url) }

        // Two tight lines, a large vertical gap, then two more tight lines.
        try writeTextPDF(to: url, lines: [
            Line(text: "Marketers have long talked", x: 72, y: 720, fontSize: 12),
            Line(text: "about the five Ps of marketing.", x: 72, y: 704, fontSize: 12),
            Line(text: "This is the marketing checklist", x: 72, y: 560, fontSize: 12),
            Line(text: "a quick way to make sure.", x: 72, y: 544, fontSize: 12),
        ])

        let paragraphs = PDFReadAloudParagraphs.extract(from: try firstPage(of: url))

        #expect(paragraphs.count == 2, "got \(paragraphs)")
        #expect(paragraphs[0].contains("five Ps"))
        #expect(paragraphs[1].contains("marketing checklist"))
    }

    @Test("Tightly-spaced lines stay one paragraph")
    func tightLinesStayOne() throws {
        let url = makeTempURL("one-para")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeTextPDF(to: url, lines: [
            Line(text: "Line one of the paragraph", x: 72, y: 720, fontSize: 12),
            Line(text: "line two of the paragraph", x: 72, y: 704, fontSize: 12),
            Line(text: "line three of the paragraph.", x: 72, y: 688, fontSize: 12),
        ])

        let paragraphs = PDFReadAloudParagraphs.extract(from: try firstPage(of: url))

        #expect(paragraphs.count == 1, "got \(paragraphs)")
    }
}
