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
    public static func enriching(
        _ locator: Locator,
        with pdfSelection: PDFSelection,
        in document: PDFKit.PDFDocument? = nil
    ) -> Locator {
        var enriched = enriching(locator, with: lineRects(from: pdfSelection))
        guard let page = pdfSelection.pages.first,
              document.map({ document in
                  guard let locatorPage = locator.locations.page else { return false }
                  let index = document.index(for: page)
                  return index >= 0 && index + 1 == locatorPage
              }) ?? true,
              let offset = selectedTextStartUTF16Offset(from: pdfSelection, on: page)
        else { return enriched }

        enriched = enriched.copy(locations: { locations in
            locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.selectionStartUTF16] = .integer(offset)
        })
        return enriched
    }

    /// Returns the first native PDFKit text-range start in page-local UTF-16
    /// coordinates. The resulting range is checked against the page's source
    /// string before it can be attached to a locator.
    public static func selectedTextStartUTF16Offset(
        from selection: PDFSelection,
        on page: PDFPage
    ) -> Int? {
        guard selection.pages.contains(where: { $0 === page }),
              selection.numberOfTextRanges(on: page) > 0,
              let pageText = page.string
        else { return nil }

        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location <= pageText.utf16.count,
              range.length <= pageText.utf16.count - range.location
        else { return nil }
        return range.location
    }

    /// Returns `locator` with already-resolved PDF user-space rects attached.
    /// This is used when Readium has retained the selection frame but PDFKit
    /// has already cleared its live `PDFSelection` object.
    public static func enriching(_ locator: Locator, with rects: [CGRect]) -> Locator {
        guard !rects.isEmpty else { return locator }
        return LocatorHighlightGeometry.attaching(rects: rects, to: locator)
    }
}
