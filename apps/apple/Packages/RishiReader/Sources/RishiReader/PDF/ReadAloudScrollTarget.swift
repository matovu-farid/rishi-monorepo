//
//  ReadAloudScrollTarget.swift
//  RishiReader
//
//  Pure Mode-A read-aloud auto-scroll offset math (Phase 30).
//
//  Maps a spoken passage's top edge (in content coordinates), the viewport
//  height, and the content height into the vertical content offset that brings
//  the passage's top to `topMargin` points below the viewport top, clamped to the
//  valid scroll range. The UIKit glue that converts a PDFSelection's page rect
//  into content coordinates and applies the offset with
//  `setContentOffset(_:animated:)` lives in plan 30-05; this type is the pure,
//  unit-testable core.
//
//  Pure: no UIKit, no PDFKit, no `#if targetEnvironment(macCatalyst)`. Mirrors
//  the `target.y = max(0, ... .minY - 80)` anchoring from RESEARCH "Auto-scroll
//  at the existing seam (Mode A)".
//

import CoreGraphics

public enum ReadAloudScrollTarget {
    /// Default upper-margin anchoring: the spoken passage's top edge lands this
    /// many points below the viewport top (matches RESEARCH's `- 80`).
    public static let defaultTopMargin: CGFloat = 80

    /// Pure. Computes the vertical content offset that brings a spoken passage's
    /// top edge to `topMargin` points below the viewport top, clamped to the valid
    /// scroll range `[0, max(0, contentHeight - viewportHeight)]`.
    public static func targetOffsetY(
        passageMinY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        topMargin: CGFloat = defaultTopMargin
    ) -> CGFloat {
        let desired = passageMinY - topMargin
        let maxOffset = max(0, contentHeight - viewportHeight)
        return min(max(0, desired), maxOffset)
    }
}
