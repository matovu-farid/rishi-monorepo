import Foundation
import PDFKit
import CoreGraphics


/// Pure-Swift adapter: turns a PDFKit `PDFSelection` into the persistent shape
/// the reader stores — a ``PDFHighlightLocator`` (page index + per-line rects
/// in PDF user-space + selected text).
///
/// **Design — `enum` with static methods.** `PDFSelection` is a non-Sendable
/// Objective-C reference type. Wrapping it in an actor would force callers to
/// `await` the coordinator and would not buy any safety (the work is a sync
/// projection of inputs). A static-method namespace is the canonical pattern
/// for a pure adapter that never owns state.
///
/// Call site (plan 05-06 view extension): when the PDFView coordinator receives
/// `.PDFViewSelectionChanged`, it reads `pdfView.currentSelection` and asks
/// this enum for a locator. The locator then flows into
/// `PDFReaderViewModel.createHighlight(color:locator:store:)`.
public enum PDFSelectionCoordinator {

    /// Builds a ``PDFHighlightLocator`` from a `PDFSelection`.
    ///
    /// Returns `nil` when the selection is empty (no per-line subselections)
    /// or when the first selected page is not part of `document` (defensive —
    /// `PDFDocument.index(for:)` returns a negative sentinel in that case).
    ///
    /// - Parameters:
    ///   - selection: The active selection (typically `pdfView.currentSelection`).
    ///   - document: The document the selection belongs to. Used to map the
    ///     `PDFPage` back to an integer index — `PDFHighlightLocator.page`.
    /// - Returns: A locator on success; `nil` on empty / unmappable input.
    public static func makeLocator(
        from selection: PDFSelection,
        in document: PDFDocument
    ) -> PDFHighlightLocator? {
        let perLine = selection.selectionsByLine()
        guard let firstPage = perLine.first?.pages.first else { return nil }
        let pageIndex = document.index(for: firstPage)
        // PDFDocument returns -1 (NSNotFound on some SDKs) when the page is
        // not in this document. Treat any negative result as unmappable.
        guard pageIndex >= 0 else { return nil }

        // One CGRect per line, in PDF user-space (origin lower-left, points,
        // mediaBox-relative). The overlay renderer (plan 05-06 Task 4)
        // converts each rect to view-space via `PDFView.convert(_:to:)`.
        let rects: [CGRect] = perLine.compactMap { lineSel in
            guard let page = lineSel.pages.first else { return nil }
            return lineSel.bounds(for: page)
        }

        // `PDFSelection.string` is optional — fall back to an empty string
        // rather than failing the whole selection (the rects are still
        // useful for visual reproduction).
        let text = selection.string ?? ""
        return PDFHighlightLocator(page: pageIndex, rects: rects, text: text)
    }
}
