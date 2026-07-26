import SwiftUI
#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator




/// Builds Readium ``Decoration`` values from persisted ``Highlight`` rows.
///
/// Shared by EPUB (HTML decorations) and PDF (``PDFDecorableNavigator``
/// annotations) so both formats paint identical tint / id / locator
/// contracts. Group name is ``groupName`` (`"rishi-highlights"`).
public enum ReaderHighlightDecorationBuilder {

    /// Decoration group key shared with ``EPUBDecorationApplier``.
    public static let groupName = "rishi-highlights"

    /// Maps every decodable highlight to a Readium decoration. Skips rows
    /// whose locator cannot be decoded (logged at warning).
    ///
    /// Accepts ``EPUBHighlightLocator`` (`epub-v1`, including PDF rows that
    /// wrap a Readium Locator) and legacy ``PDFHighlightLocator`` (`pdf-v1`
    /// with 0-based page + rects).
    public static func make(from highlights: [Highlight]) -> [Decoration] {
        highlights.compactMap { highlight in
            guard let locator = decodeLocator(from: highlight.locatorStart) else {
                Log.reader.warning(
                    "Skipping malformed highlight \(highlight.id.uuidString, privacy: .public)"
                )
                return nil
            }
            return Decoration(
                id: highlight.id.uuidString,
                locator: locator,
                style: .highlight(tint: uiColor(for: highlight.color), isActive: false)
            )
        }
    }

    /// Decodes `epub-v1` first; on failure tries legacy `pdf-v1`.
    private static func decodeLocator(from jsonString: String) -> Locator? {
        if let wrapper = try? EPUBHighlightLocator.decode(jsonString: jsonString),
           let locator = wrapper.toReadiumLocator() {
            return locator
        }
        if let pdfLocator = try? PDFHighlightLocator.decode(jsonString: jsonString) {
            return readiumLocator(from: pdfLocator)
        }
        return nil
    }

    /// Converts a legacy ``PDFHighlightLocator`` (0-based page) into a
    /// Readium Locator with `page=N` (1-based) + rect geometry.
    private static func readiumLocator(from pdfLocator: PDFHighlightLocator) -> Locator? {
        guard let href = AnyURL(string: "/") else { return nil }
        let base = Locator(
            href: href,
            mediaType: .pdf,
            locations: Locator.Locations(fragments: ["page=\(pdfLocator.page + 1)"]),
            text: Locator.Text(highlight: pdfLocator.text)
        )
        return LocatorHighlightGeometry.attaching(rects: pdfLocator.rects, to: base)
    }

    /// Maps the persisted `HighlightColor` to the matching RishiUIKit
    /// asset token at ``HighlightColor/pageOverlayOpacity``.
    public static func uiColor(for color: HighlightColor) -> UIColor {
        let tint: UIColor
        switch color {
        case .yellow: tint = UIColor(RishiColor.highlightYellow)
        case .pink:   tint = UIColor(RishiColor.highlightPink)
        case .green:  tint = UIColor(RishiColor.highlightGreen)
        case .blue:   tint = UIColor(RishiColor.highlightBlue)
        }
        return tint.withAlphaComponent(color.pageOverlayOpacity)
    }
}
#endif
