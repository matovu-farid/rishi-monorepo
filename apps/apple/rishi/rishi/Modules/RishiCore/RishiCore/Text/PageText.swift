//
//  PageText.swift
//  RishiCore — Phase 27 plan 27-01
//
//  Layout-aware PDF text primitives shared between RishiReader's
//  PDFLayoutExtractor (producer) and the footer-detection strategies in
//  RishiCore (consumers — Phase 27-04 RepetitionFooterStrategy and
//  Phase 27-05 FootnoteDetector).
//
//  Public API deliberately uses Foundation + CoreGraphics only — no PDFKit
//  import — so RishiCore stays portable and downstream strategies can
//  pattern-match on these values without dragging PDFKit into the core
//  domain layer.
//
//  Mirrors the shape of electron's pdf.js `TextContent.items` so the
//  ported strategies behave identically given equivalent input.
//

import Foundation
import CoreGraphics

/// One run of text laid out on a PDF page.
///
/// The Phase 27-01 producer (`PDFLayoutExtractor`) emits one `TextItem`
/// per line (via PDFKit `selectionsByLine`), not per glyph run. That's
/// coarser than pdf.js `TextItem` granularity but sufficient for
/// `RepetitionFooterStrategy`, which bins by y-coordinate (one bin per
/// line anyway).
public struct TextItem: Sendable, Equatable {
    /// Verbatim line text. Concatenating items on one line reconstructs
    /// the rendered line.
    public let text: String

    /// User-space frame in PDF coordinates (origin bottom-left).
    public let frame: CGRect

    /// Approximate rendered font size in PDF user-space units.
    ///
    /// Derived from the line's bounding-box height — this is an
    /// approximation (descenders inflate it, small caps confuse it), but
    /// it's good enough for `FootnoteDetector`'s `smallFontRatio = 0.85`
    /// comparison because that heuristic is **relative** (compares to the
    /// median body height on the same page), not absolute.
    public let fontSize: CGFloat

    public init(text: String, frame: CGRect, fontSize: CGFloat) {
        self.text = text
        self.frame = frame
        self.fontSize = fontSize
    }
}

/// All text items extracted from a single PDF page, in PDF stream order.
public struct PageText: Sendable, Equatable {
    /// 0-based PDF page index (matches `PDFDocument.page(at:)`).
    public let pageIndex: Int

    /// Page mediaBox in user-space coordinates (origin bottom-left).
    public let frame: CGRect

    /// Items in PDF stream order. The array index is the addressable
    /// identity used by `FooterMask` in Phase 27-06.
    public let items: [TextItem]

    public init(pageIndex: Int, frame: CGRect, items: [TextItem]) {
        self.pageIndex = pageIndex
        self.frame = frame
        self.items = items
    }
}
