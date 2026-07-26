import Foundation
import CoreGraphics
import PDFKit
import ReadiumShared

/// Attaches PDFKit selection geometry onto a Readium ``Locator`` so unified
/// PDF highlights can persist and paint via ``LocatorHighlightGeometry``.
///
/// Readium's PDF `Selection.locator` carries page + text but not per-line
/// rects. ``PDFDecorableNavigator`` needs those rects under
/// ``LocatorHighlightGeometry/rectsKey``. This helper mirrors the line-rect
/// extraction in ``PDFSelectionCoordinator`` and writes them with
/// ``LocatorHighlightGeometry/attaching(rects:to:)``.
public enum PDFSelectionLocatorEnricher {

    /// Prefers per-line rects; when those are empty, uses whole-selection
    /// fallback bounds (one rect per page). Pure seam for unit tests.
    public static func resolveRects(
        lineRects: [CGRect],
        fallbackRects: [CGRect]
    ) -> [CGRect] {
        lineRects.isEmpty ? fallbackRects : lineRects
    }

    /// One CGRect per line in PDF user space (origin lower-left), matching
    /// ``PDFSelectionCoordinator``'s extraction. When `selectionsByLine()`
    /// is empty, falls back to `bounds(for:)` on each selected page.
    public static func lineRects(from selection: PDFSelection) -> [CGRect] {
        let perLine = selection.selectionsByLine().compactMap { lineSel -> CGRect? in
            guard let page = lineSel.pages.first else { return nil }
            return lineSel.bounds(for: page)
        }
        let fallback = selection.pages.compactMap { page -> CGRect? in
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            return bounds
        }
        return resolveRects(lineRects: perLine, fallbackRects: fallback)
    }

    /// Returns `locator` with line rects from `pdfSelection` attached.
    /// When the selection has no usable rects, returns `locator` unchanged.
    public static func enriching(_ locator: Locator, with pdfSelection: PDFSelection) -> Locator {
        enriching(locator, with: lineRects(from: pdfSelection))
    }

    /// Returns `locator` with already-resolved PDF user-space rects attached.
    /// This is used when Readium has retained the selection frame but PDFKit
    /// has already cleared its live `PDFSelection` object.
    public static func enriching(_ locator: Locator, with rects: [CGRect]) -> Locator {
        guard !rects.isEmpty else { return locator }
        return LocatorHighlightGeometry.attaching(rects: rects, to: locator)
    }
}
