#if canImport(UIKit)
import Foundation
import PDFKit


/// Builds a `PDFSelection` for the paragraph currently being read aloud so
/// the reader can surface it via `PDFView.highlightedSelections` without
/// disturbing the user's own text selection.
///
/// The read-aloud bridge tracks the spoken passage as a 0-based index into
/// `ParagraphChunker.chunk(_:)` output. To draw an inline highlight we map
/// that paragraph string back to a character range in `PDFPage.string`
/// (whitespace-tolerant, via ``RishiCore/ReadAloudParagraphLocator``) and
/// turn the range into a `PDFSelection` with
/// `PDFDocument.selection(from:atCharacterIndex:to:atCharacterIndex:)`.
public enum PDFReadAloudHighlighter {

    /// Returns a selection covering `paragraph` on `page`, or `nil` when the
    /// page has no extractable text or the paragraph cannot be located
    /// (e.g. scanned image-only PDFs, or a stale index after a page turn).
    public static func selection(in page: PDFPage, paragraph: String) -> PDFSelection? {
        guard let pageString = page.string, !pageString.isEmpty else { return nil }
        guard let range = ReadAloudParagraphLocator.range(of: paragraph, in: pageString)
        else { return nil }

        let lower = pageString.distance(from: pageString.startIndex, to: range.lowerBound)
        let upper = pageString.distance(from: pageString.startIndex, to: range.upperBound)
        guard upper > lower, let document = page.document else { return nil }
        // Character-index selections live on PDFDocument, not PDFPage; the
        // upper bound is exclusive in our range but PDFKit wants the index of
        // the last selected character, so step back one.
        return document.selection(
            from: page, atCharacterIndex: lower,
            to: page, atCharacterIndex: upper - 1
        )
    }
}
#endif
