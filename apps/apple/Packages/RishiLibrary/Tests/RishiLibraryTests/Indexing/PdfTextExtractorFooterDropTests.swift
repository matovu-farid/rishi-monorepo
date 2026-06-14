//
//  PdfTextExtractorFooterDropTests.swift
//  RishiLibraryTests (Phase 27 plan 27-06)
//
//  Integration coverage for the Phase 27 footer-drop toggle on
//  `PdfTextExtractor`. Builds synthetic PDFs via CoreGraphics (real,
//  selectable text — not rasterised) and asserts:
//
//    1. `footerPolicy: .disabled` produces Phase 26 byte-stable output
//       (the "Page N" trailers survive — regression evidence).
//    2. `footerPolicy: .enabled` drops the trailing "Page N" paragraphs
//       on a 10-page PDF where the trailer is the only recurring footer.
//    3. Under-min-pages PDFs (< 8 pages) preserve trailers even when the
//       toggle is enabled.
//    4. Toggle-enabled with no detectable footer matches the disabled
//       path.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import RishiLibrary
import RishiCore

@Suite("PdfTextExtractor footer-drop (27-06)", .serialized)
struct PdfTextExtractorFooterDropTests {

    // MARK: - Fixture helpers

    private static let pageSize = CGSize(width: 612, height: 792) // US Letter

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString).pdf"
        )
    }

    /// Writes a multi-page PDF where each page renders the given lines as
    /// real PDF text. Mirrors the helper in `PDFLayoutExtractorTests`.
    private func writeTextPDF(to url: URL, pages: [[Line]]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create CGContext for PDF")
            return
        }
        for lines in pages {
            ctx.beginPDFPage(nil)
            for line in lines {
                let font = CTFontCreateWithName(
                    "Helvetica" as CFString,
                    line.fontSize,
                    nil
                )
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: CGColor(gray: 0, alpha: 1)
                ]
                let attributed = NSAttributedString(string: line.text, attributes: attrs)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                ctx.textPosition = CGPoint(x: line.x, y: line.y)
                CTLineDraw(ctLine, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// 10 pages, each with a substantial body and a trailing "Page N" line
    /// at the bottom. Per-page body uses a non-numeric tag so
    /// FooterTokens.normalize keeps bodies distinct.
    ///
    /// Layout note: we place the body lines clustered near the top and the
    /// "Page N" trailer near the bottom with a wide vertical gap. PDFKit's
    /// `page.string` is observed (Apple PDFKit on macOS 14) to insert a
    /// double-newline between visually-separated text runs, which lets
    /// `ParagraphChunker.chunk` split the body and trailer into separate
    /// paragraphs as required by `SuffixFooterStrategy` (it works on the
    /// per-page paragraph stream's trailing slot).
    private func makeTenPagePdfWithTrailer(at url: URL) throws {
        // Use long enough body so it survives ParagraphChunker's indexing
        // heuristic and is clearly distinguished from the short trailer.
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [[Line]] = (1...10).map { n in
            let tag = bodyTags[n - 1]
            return [
                // Body block near the top.
                Line(
                    text: "This is the unique \(tag) body content of page \(n), long enough to register as a body paragraph and remain distinct after FooterTokens normalization across the document corpus.",
                    x: 72, y: 720, fontSize: 12
                ),
                Line(
                    text: "Second line of unique \(tag) body content, kept distinct per page so the suffix detector does not confuse it with the trailer.",
                    x: 72, y: 700, fontSize: 12
                ),
                // The trailing page-number footer at the bottom — large
                // vertical gap from the body so PDFKit emits a blank-line
                // boundary between them.
                Line(text: "Page \(n)", x: 72, y: 60, fontSize: 10),
            ]
        }
        try writeTextPDF(to: url, pages: pages)
    }

    /// 5 pages with the same body + trailer pattern — below the default
    /// minPages = 8 floor.
    private func makeFivePagePdfWithTrailer(at url: URL) throws {
        let bodyTags = ["alpha","bravo","charlie","delta","echo"]
        let pages: [[Line]] = (1...5).map { n in
            let tag = bodyTags[n - 1]
            return [
                Line(
                    text: "This is the unique \(tag) body content of page \(n), kept long enough that the chunker treats it as a real body paragraph and not a header.",
                    x: 72, y: 720, fontSize: 12
                ),
                Line(text: "Page \(n)", x: 72, y: 60, fontSize: 10),
            ]
        }
        try writeTextPDF(to: url, pages: pages)
    }

    /// 10 pages with unique non-recurring content (no detectable footer).
    private func makeTenPagePdfWithoutFooter(at url: URL) throws {
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [[Line]] = (1...10).map { n in
            let tag = bodyTags[n - 1]
            return [
                Line(
                    text: "Unique body line for the \(tag) page in this corpus, long enough to register as a real paragraph.",
                    x: 72, y: 720, fontSize: 12
                ),
                // No trailing page number / repeating footer.
            ]
        }
        try writeTextPDF(to: url, pages: pages)
    }

    // MARK: - 1. Disabled => Phase 26 baseline (trailers survive)

    @Test("Toggle .disabled preserves trailing 'Page N' paragraphs")
    func disabledPreservesTrailers() async throws {
        let url = makeTempURL("disabled-trailers")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTenPagePdfWithTrailer(at: url)

        let extractor = PdfTextExtractor(footerPolicy: .disabled)
        let rows = try await extractor.extractParagraphs(from: url)

        // Every "Page N" trailer should appear in the rows for n in 1...10.
        let allText = rows.map(\.text).joined(separator: "\n")
        for n in 1...10 {
            #expect(
                allText.contains("Page \(n)"),
                "Toggle off should preserve 'Page \(n)' trailer (Phase 26 byte parity)"
            )
        }
    }

    // MARK: - 2. Enabled => trailing 'Page N' dropped

    @Test("Toggle .enabled drops trailing 'Page N' paragraphs on a 10-page PDF")
    func enabledDropsTrailers() async throws {
        let url = makeTempURL("enabled-trailers")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTenPagePdfWithTrailer(at: url)

        let extractor = PdfTextExtractor(footerPolicy: .enabled)
        let rows = try await extractor.extractParagraphs(from: url)

        // None of the "Page 1".."Page 10" trailers should survive as a
        // standalone paragraph.
        for n in 1...10 {
            let standalone = rows.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Page \(n)" }
            #expect(!standalone, "Toggle on should drop standalone 'Page \(n)' trailer")
        }
        // Body paragraphs should still be present.
        #expect(!rows.isEmpty, "Body content should survive footer drop")
    }

    // MARK: - 3. Under-min-pages => no-op even with toggle .enabled

    @Test("Under-minPages PDF preserves trailers even with toggle .enabled")
    func underMinPagesPreservesTrailers() async throws {
        let url = makeTempURL("under-min")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeFivePagePdfWithTrailer(at: url)

        let extractor = PdfTextExtractor(footerPolicy: .enabled)
        let rows = try await extractor.extractParagraphs(from: url)
        let allText = rows.map(\.text).joined(separator: "\n")
        for n in 1...5 {
            #expect(
                allText.contains("Page \(n)"),
                "5-page PDF is below minPages; trailers must survive"
            )
        }
    }

    // MARK: - 4. Enabled + no recurring footer => same as disabled

    @Test("Toggle .enabled with no detectable footer matches disabled output")
    func enabledNoFooterMatchesDisabled() async throws {
        let url = makeTempURL("no-footer")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTenPagePdfWithoutFooter(at: url)

        let disabledExtractor = PdfTextExtractor(footerPolicy: .disabled)
        let enabledExtractor = PdfTextExtractor(footerPolicy: .enabled)

        let disabledRows = try await disabledExtractor.extractParagraphs(from: url)
        let enabledRows = try await enabledExtractor.extractParagraphs(from: url)

        #expect(disabledRows.count == enabledRows.count, "Row count must match when no footer is detected")
        for (a, b) in zip(disabledRows, enabledRows) {
            #expect(a.page == b.page)
            #expect(a.text == b.text)
        }
    }

    // MARK: - 5. Default init preserves Phase 26 behavior

    @Test("Default init (no argument) defaults to .disabled and matches Phase 26")
    func defaultInitIsDisabled() async throws {
        let url = makeTempURL("default-init")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTenPagePdfWithTrailer(at: url)

        let defaultExtractor = PdfTextExtractor()
        let disabledExtractor = PdfTextExtractor(footerPolicy: .disabled)

        let defaultRows = try await defaultExtractor.extractParagraphs(from: url)
        let disabledRows = try await disabledExtractor.extractParagraphs(from: url)

        #expect(defaultRows.count == disabledRows.count)
        for (a, b) in zip(defaultRows, disabledRows) {
            #expect(a.page == b.page)
            #expect(a.text == b.text)
        }
        #expect(defaultExtractor.footerPolicy == .disabled, "Default init must be .disabled per Phase 27-06 plan")
    }
}
