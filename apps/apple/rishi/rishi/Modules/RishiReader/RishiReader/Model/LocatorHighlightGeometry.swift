import CoreGraphics
import Foundation
import ReadiumShared

/// PDF highlight geometry on a Readium ``Locator``.
///
/// EPUB and PDF highlights share ``EPUBHighlightLocator`` (format `epub-v1`)
/// wrapping a Readium Locator JSON string. For PDF:
/// - **Page** comes from the existing `page=N` fragment
///   (``Locator.Locations.page``, 1-based).
/// - **Rects** are stored under ``rectsKey`` in
///   `locations.otherLocations` as `[[x0, y0, x1, y1], ...]`, in PDF
///   user space (origin lower-left, points) — the same encoding as
///   ``PDFHighlightLocator``.
///
/// Pure helpers only; no navigator dependency.
public enum LocatorHighlightGeometry {

    /// Key under `Locator.Locations.otherLocations` for PDF highlight rects.
    public static let rectsKey = "rects"

    /// Returns a copy of `locator` with `rects` written into `otherLocations`.
    ///
    /// Existing otherLocations entries are preserved; only ``rectsKey`` is
    /// replaced. Page fragments and text are left unchanged.
    public static func attaching(rects: [CGRect], to locator: Locator) -> Locator {
        locator.copy(locations: { locations in
            locations.otherLocations[rectsKey] = encodeRects(rects)
        })
    }

    /// Reads PDF user-space rects from `otherLocations[rectsKey]`.
    ///
    /// - Returns: Decoded rects, or `nil` when the key is absent or not an
    ///   array. Malformed entries inside a valid array are skipped.
    public static func rects(from locator: Locator) -> [CGRect]? {
        guard let value = locator.locations.otherLocations[rectsKey] else {
            return nil
        }
        guard let arrays = value.array else {
            return nil
        }
        return arrays.compactMap(decodeRect)
    }

    /// 1-based page from the locator's `page=N` fragment, if present.
    public static func page(from locator: Locator) -> Int? {
        locator.locations.page
    }

    // MARK: - Encoding

    private static func encodeRects(_ rects: [CGRect]) -> JSONValue {
        .array(rects.map { rect in
            .array([
                jsonNumber(rect.minX),
                jsonNumber(rect.minY),
                jsonNumber(rect.maxX),
                jsonNumber(rect.maxY),
            ])
        })
    }

    private static func jsonNumber(_ value: CGFloat) -> JSONValue {
        let double = Double(value)
        if double.rounded() == double, let int = Int(exactly: double) {
            return .integer(int)
        }
        return .double(double)
    }

    private static func decodeRect(_ value: JSONValue) -> CGRect? {
        guard let coords = value.array, coords.count >= 4,
              let x0 = coords[0].double,
              let y0 = coords[1].double,
              let x1 = coords[2].double,
              let y1 = coords[3].double
        else {
            return nil
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
