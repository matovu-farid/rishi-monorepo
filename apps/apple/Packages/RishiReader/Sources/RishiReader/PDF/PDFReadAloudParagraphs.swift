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
