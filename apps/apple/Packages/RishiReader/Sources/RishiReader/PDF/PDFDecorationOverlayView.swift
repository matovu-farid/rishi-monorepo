#if canImport(UIKit)
import Foundation
import CoreGraphics
import PDFKit
import UIKit

/// UIView overlay that paints decoration specs above PDFKit content.
///
/// PDFKit ``PDFAnnotation`` rendering is flaky under Readium's
/// `usePageViewController` path. This view mirrors the working
/// ``PDFHighlightOverlay`` approach: convert page-space rects via
/// ``PDFView/convert(_:from:)`` and fill with the tint already carrying
/// ``HighlightColor/pageOverlayOpacity``.
public final class PDFDecorationOverlayView: UIView {

    public weak var pdfView: PDFView?

    /// Draw models currently shown (flattened across decoration groups).
    public private(set) var specs: [PDFDecorationAnnotationSpec] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the full flattened draw list and triggers a redraw.
    public func replaceSpecs(_ specs: [PDFDecorationAnnotationSpec]) {
        self.specs = specs
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard let pdfView, let context = UIGraphicsGetCurrentContext() else { return }

        for spec in specs {
            guard let page = pdfView.document?.page(at: spec.pageIndex) else { continue }
            let viewRect = pdfView.convert(spec.bounds, from: page)
            // Sibling (or child) overlay: map PDFView-space rects into local.
            let localRect = convert(viewRect, from: pdfView)
            guard !localRect.isNull, !localRect.isEmpty else { continue }
            context.setFillColor(spec.color.cgColor)
            context.fill(localRect)
        }
    }
}
#endif
