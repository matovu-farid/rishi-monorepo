#if canImport(UIKit)
import Foundation
import CoreGraphics
import PDFKit
import UIKit
import ReadiumNavigator
import ReadiumShared


/// Descriptor for a PDFKit annotation derived from a Readium ``Decoration``.
public struct PDFDecorationAnnotationSpec: @unchecked Sendable {
    /// 0-based PDFKit page index (`page=N` fragment minus one).
    public let pageIndex: Int
    /// Bounds in PDF user space.
    public let bounds: CGRect
    /// Tint including ``HighlightColor/pageOverlayOpacity``.
    public let color: UIColor
    public let decorationId: String
    public let group: String
}

/// Pure planner: turns Readium decorations into PDF annotation specs.
///
/// Geometry comes from ``LocatorHighlightGeometry`` (1-based `page=N`
/// fragment + `otherLocations["rects"]`). Only `.highlight` and
/// `.underline` styles produce specs; underline is painted as the same
/// filled highlight as EPUB parity.
public enum PDFDecorationAnnotator {

    /// `PDFAnnotation` key for the decoration group name.
    public static let groupUserInfoKey = "rishiDecorationGroup"
    /// `PDFAnnotation` key for the decoration id within the group.
    public static let idUserInfoKey = "rishiDecorationId"

    /// Annotation dictionary keys used to tag decorations we own.
    public static var groupAnnotationKey: PDFAnnotationKey {
        PDFAnnotationKey(rawValue: groupUserInfoKey)
    }

    public static var idAnnotationKey: PDFAnnotationKey {
        PDFAnnotationKey(rawValue: idUserInfoKey)
    }

    /// Builds annotation specs for highlight/underline decorations that carry
    /// page + rect geometry via ``LocatorHighlightGeometry``.
    public static func specs(
        from decorations: [Decoration],
        in group: String
    ) -> [PDFDecorationAnnotationSpec] {
        decorations.flatMap { decoration -> [PDFDecorationAnnotationSpec] in
            guard isSupportedStyle(decoration.style),
                  let page = LocatorHighlightGeometry.page(from: decoration.locator),
                  page >= 1,
                  let rects = LocatorHighlightGeometry.rects(from: decoration.locator),
                  !rects.isEmpty
            else {
                return []
            }

            let color = resolvedColor(for: decoration.style)
            let pageIndex = page - 1
            return rects.map { rect in
                PDFDecorationAnnotationSpec(
                    pageIndex: pageIndex,
                    bounds: rect,
                    color: color,
                    decorationId: decoration.id,
                    group: group
                )
            }
        }
    }

    /// Z-pattern quad points for a single-rect highlight annotation whose
    /// `bounds` equal `bounds` (relative to the annotation origin, PDF y-up):
    /// upper-left, upper-right, lower-left, lower-right.
    ///
    /// PDFKit highlight annotations typically do not render without these.
    public static func quadrilateralPoints(for bounds: CGRect) -> [NSValue] {
        [
            NSValue(cgPoint: CGPoint(x: 0, y: bounds.height)),           // UL
            NSValue(cgPoint: CGPoint(x: bounds.width, y: bounds.height)), // UR
            NSValue(cgPoint: CGPoint(x: 0, y: 0)),                        // LL
            NSValue(cgPoint: CGPoint(x: bounds.width, y: 0)),             // LR
        ]
    }

    /// Applies ownership tags onto a PDFKit annotation.
    public static func applyTags(to annotation: PDFAnnotation, for spec: PDFDecorationAnnotationSpec) {
        annotation.setValue(spec.group, forAnnotationKey: groupAnnotationKey)
        annotation.setValue(spec.decorationId, forAnnotationKey: idAnnotationKey)
    }

    /// Group tag stored on `annotation`, if we wrote one.
    public static func group(from annotation: PDFAnnotation) -> String? {
        annotation.value(forAnnotationKey: groupAnnotationKey) as? String
    }

    /// Decoration id tag stored on `annotation`, if we wrote one.
    public static func decorationId(from annotation: PDFAnnotation) -> String? {
        annotation.value(forAnnotationKey: idAnnotationKey) as? String
    }

    /// UserInfo-style dictionary of ownership tags (for tests / diagnostics).
    public static func userInfo(for spec: PDFDecorationAnnotationSpec) -> [AnyHashable: Any] {
        [
            groupUserInfoKey: spec.group,
            idUserInfoKey: spec.decorationId,
        ]
    }

    // MARK: - Private

    private static func isSupportedStyle(_ style: Decoration.Style) -> Bool {
        style.id == .highlight || style.id == .underline
    }

    private static func resolvedColor(for style: Decoration.Style) -> UIColor {
        let opacity = HighlightColor.yellow.pageOverlayOpacity
        let tint = (style.config as? Decoration.Style.HighlightConfig)?.tint
            ?? UIColor.systemYellow
        return tint.withAlphaComponent(opacity)
    }
}
#endif
