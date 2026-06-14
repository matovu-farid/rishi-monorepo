//
//  PDFLayoutExtractor.swift
//  RishiReader — Phase 27 plan 27-01
//
//  Layout-aware PDF text extraction. Returns a per-page sequence of
//  `TextItem` values with frames + approximate font sizes, mirroring the
//  shape of electron's pdf.js `TextContent.items` so the ported footer
//  strategies in Phase 27-04 / 27-05 can read the same structure.
//
//  Implementation strategy: PDFKit `PDFPage.selectionsByLine()`. This is
//  one `TextItem` per LINE (not per glyph run). That's sufficient for
//  `RepetitionFooterStrategy` (Phase 27-04) which already bins by
//  y-coordinate (one bin per line). For `FootnoteDetector` (Phase 27-05),
//  the `fontSize = frame.height` approximation is RELATIVE — compared to
//  the median body height on the same page — so the heuristic is robust
//  to the small bias the bounding-box-height proxy introduces.
//
//  Stretch path documented but unimplemented: a `CGPDFScannerCreate`-based
//  scanner could recover per-glyph layout if `selectionsByLine` loses too
//  much granularity in real-world PDFs. Tracked in `27-PLAN.md` Risk R1.
//

import Foundation
import CoreGraphics
import PDFKit
import RishiCore

/// Layout-aware PDF text extractor.
///
/// `@MainActor` because PDFKit's `PDFDocument` / `PDFPage` APIs are not
/// thread-safe and Apple's guidance is to drive them from the main actor.
/// If profiling shows the extraction loop is hot on large books, the
/// orchestrator can hop into the extractor from a background task — the
/// hop is cheap.
@MainActor
public enum PDFLayoutExtractor {

    /// Errors surfaced by the extractor.
    public enum ExtractionError: Error, Equatable {
        /// File at URL is missing or not a valid PDF.
        case unreadableDocument(URL)
    }

    /// Extract per-page layout-aware text from the PDF at `url`.
    ///
    /// - Parameter url: file URL of a PDF on disk.
    /// - Returns: One `PageText` per PDF page, in page order. Returns
    ///   `[]` for an empty (0-page) document. Pages with no selectable
    ///   text (e.g. scanned image-only PDFs) yield a `PageText` with an
    ///   empty `items` array — downstream strategies are expected to
    ///   handle that case.
    /// - Throws: `ExtractionError.unreadableDocument` if PDFKit cannot
    ///   open the file at `url`.
    public static func extract(_ url: URL) async throws -> [PageText] {
        guard let doc = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument(url)
        }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return [] }

        var pages: [PageText] = []
        pages.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let charCount = page.numberOfCharacters
            let lines: [PDFSelection]
            if charCount > 0,
               let pageSelection = page.selection(for: NSRange(location: 0, length: charCount)) {
                lines = pageSelection.selectionsByLine()
            } else {
                lines = []
            }

            var items: [TextItem] = []
            items.reserveCapacity(lines.count)
            for line in lines {
                guard let raw = line.string else { continue }
                let text = raw
                guard !text.isEmpty else { continue }
                let frame = line.bounds(for: page)
                // fontSize is approximated by the line bounding-box height.
                // Descenders inflate it relative to true cap height, but
                // FootnoteDetector compares it to the per-page median of
                // the same approximation, so the bias cancels out.
                items.append(TextItem(
                    text: text,
                    frame: frame,
                    fontSize: frame.height
                ))
            }

            pages.append(PageText(
                pageIndex: pageIndex,
                frame: mediaBox,
                items: items
            ))
        }
        return pages
    }
}
