//
//  PDFReadAloudParagraphs.swift
//  RishiReader
//
//  Layout-aware paragraph extraction for PDF read-aloud (TTS).
//
//  `PDFPage.string` joins visual lines with single `\n` and carries no
//  blank-line paragraph boundaries, so feeding it to `ParagraphChunker`
//  produced one page-sized chunk (and one page-spanning highlight). This
//  recovers paragraph structure from line geometry: PDFKit's
//  `selectionsByLine()` gives one selection per rendered line, which
//  `PdfParagraphGrouper` groups into paragraphs by vertical spacing.
//
//  `nonisolated` to match the read-aloud call site
//  (`PDFReaderViewModel.paragraphsForReadAloud`, F-P0-06), which runs the
//  PDFKit text read on a detached task and only touches the passed-in page —
//  the same off-main access pattern the prior `page.string` call used.
//

import Foundation
import CoreGraphics
import PDFKit
import RishiCore

public enum PDFReadAloudParagraphs {

    /// Full read-aloud paragraph production for a single page. Prefers
    /// layout-aware boundaries (line geometry) via ``extract(from:)`` so a
    /// page splits into real paragraphs; for pages with no selectable text
    /// (scanned / image-only) it falls back to blank-line chunking of the raw
    /// page string. Both paths route through `ParagraphChunker.chunk(_:)` so
    /// downstream paragraph semantics (and the >4096-char subdivide) match.
    /// Returns `[]` when the page yields no text at all.
    ///
    /// This is the single source of per-page paragraph extraction shared by
    /// the initial read-aloud start (`PDFReaderViewModel.paragraphsForReadAloud`)
    /// and the page-boundary continuation
    /// (``PDFReaderViewModel/paragraphsForFollowingPage()``).
    public nonisolated static func paragraphs(from page: PDFPage) -> [String] {
        let blocks = extract(from: page)
        guard !blocks.isEmpty else {
            return ParagraphChunker.chunk(page.string ?? "")
        }
        return blocks.flatMap { ParagraphChunker.chunk($0) }
    }

    /// Extract layout-aware paragraph strings from a single page. Returns
    /// `[]` for pages with no selectable text (e.g. scanned image-only PDFs);
    /// callers should fall back to `PDFPage.string` chunking in that case.
    public nonisolated static func extract(from page: PDFPage) -> [String] {
        let charCount = page.numberOfCharacters
        guard charCount > 0,
              let pageSelection = page.selection(for: NSRange(location: 0, length: charCount))
        else { return [] }

        var lines: [TextItem] = []
        for line in pageSelection.selectionsByLine() {
            guard let raw = line.string, !raw.isEmpty else { continue }
            let frame = line.bounds(for: page)
            lines.append(TextItem(text: raw, frame: frame, fontSize: frame.height))
        }
        return PdfParagraphGrouper.paragraphs(from: lines)
    }
}
