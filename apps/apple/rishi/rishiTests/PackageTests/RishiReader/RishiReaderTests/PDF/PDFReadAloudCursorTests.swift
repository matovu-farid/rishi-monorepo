@testable import rishi
//
//  PDFReadAloudCursorTests.swift
//  RishiReaderTests
//
//  Unit coverage for the extracted `PDFReadAloudCursor` (plan 34-07). Pins the
//  pure page-scan intent logic directly, independent of `PDFReaderViewModel`:
//  forward/backward scan returns the next/previous non-empty page index + its
//  paragraphs, skips pages with no selectable text, and returns nil at the
//  document boundaries. Mirrors PDFReadAloudPageContinuationTests' synthetic
//  CGContext PDF fixtures (real selectable text).
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit


@Suite("PDFReadAloudCursor", .serialized)
@MainActor
struct PDFReadAloudCursorTests {

    private static let pageSize = CGSize(width: 612, height: 792)

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
    }

    private func bodyLines(_ marker: String) -> [Line] {
        [
            Line(text: "\(marker) paragraph opens the page here", x: 72, y: 720, fontSize: 12),
            Line(text: "and continues on a second tight line.", x: 72, y: 704, fontSize: 12),
        ]
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    private func writeMultiPageTextPDF(to url: URL, pages: [[Line]]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create CGContext for PDF")
            return
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            for line in page {
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
        }
        ctx.closePDF()
    }

    private func loadDocument(_ url: URL) throws -> PDFDocument {
        try #require(PDFDocument(url: url))
    }

    // MARK: - Forward scan

    @Test("following returns the next page's index and complete paragraph list")
    func followingCrossesIntoNextPage() throws {
        let url = makeTempURL("cursor-fwd")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])
        let doc = try loadDocument(url)
        let expected = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: 1)))
        try #require(!expected.isEmpty)

        let cursor = PDFReadAloudCursor(document: doc)
        let result = try #require(cursor.following(currentPage: 0))

        #expect(result.pageIndex == 1)
        #expect(result.paragraphs == expected)
    }

    @Test("following skips pages with no selectable text")
    func followingSkipsEmptyPages() throws {
        let url = makeTempURL("cursor-fwd-skip")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), [], bodyLines("Gamma")])
        let doc = try loadDocument(url)

        let cursor = PDFReadAloudCursor(document: doc)
        let result = try #require(cursor.following(currentPage: 0))

        #expect(result.pageIndex == 2)
        #expect(result.paragraphs.joined(separator: " ").contains("Gamma"))
    }

    @Test("following returns nil past the last page")
    func followingStopsAtEnd() throws {
        let url = makeTempURL("cursor-fwd-end")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])
        let doc = try loadDocument(url)

        let cursor = PDFReadAloudCursor(document: doc)
        #expect(cursor.following(currentPage: 1) == nil)
    }

    // MARK: - Backward scan

    @Test("preceding returns the previous page's index and complete paragraph list")
    func precedingCrossesIntoPreviousPage() throws {
        let url = makeTempURL("cursor-back")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])
        let doc = try loadDocument(url)
        let expected = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: 0)))
        try #require(!expected.isEmpty)

        let cursor = PDFReadAloudCursor(document: doc)
        let result = try #require(cursor.preceding(currentPage: 1))

        #expect(result.pageIndex == 0)
        #expect(result.paragraphs == expected)
    }

    @Test("preceding skips pages with no selectable text")
    func precedingSkipsEmptyPages() throws {
        let url = makeTempURL("cursor-back-skip")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), [], bodyLines("Gamma")])
        let doc = try loadDocument(url)

        let cursor = PDFReadAloudCursor(document: doc)
        let result = try #require(cursor.preceding(currentPage: 2))

        #expect(result.pageIndex == 0)
        #expect(result.paragraphs.joined(separator: " ").contains("Alpha"))
    }

    @Test("preceding returns nil before the first page")
    func precedingStopsAtStart() throws {
        let url = makeTempURL("cursor-back-start")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])
        let doc = try loadDocument(url)

        let cursor = PDFReadAloudCursor(document: doc)
        #expect(cursor.preceding(currentPage: 0) == nil)
    }

    // MARK: - Single-page extraction

    @Test("paragraphs(atPage:) returns the page's paragraphs")
    func paragraphsAtPageMatchesExtractor() throws {
        let url = makeTempURL("cursor-page")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha")])
        let doc = try loadDocument(url)
        let expected = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: 0)))

        let cursor = PDFReadAloudCursor(document: doc)
        #expect(cursor.paragraphs(atPage: 0) == expected)
    }

    @Test("nil document yields no continuation and empty page text")
    func nilDocumentIsInert() {
        let cursor = PDFReadAloudCursor(document: nil)
        #expect(cursor.following(currentPage: 0) == nil)
        #expect(cursor.preceding(currentPage: 5) == nil)
        #expect(cursor.paragraphs(atPage: 0).isEmpty)
    }
}
