//
//  PDFMacWindowSizing.swift
//  RishiReader
//
//  Phase 30 plan 30-05 — Mac Catalyst window minimum-width clamp.
//
//  Sets `UIWindowScene.sizeRestrictions.minimumSize` so the Catalyst window can
//  never be dragged below the minimum readable PDF page width. The floor is
//  derived from the SAME `PDFReaderLayoutMetrics.minPageWidth` constant the
//  layout resolver uses for its single-vs-spread breakpoint, so the window floor
//  and the breakpoint can never desync.
//
//  The scene is reached via the established
//  `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }`
//  idiom (ManageSubscriptionPresenter.swift:68 / SiwaPresenter.swift:232) — no
//  `UIWindowSceneDelegate` exists in this app, so there is no scene-creation
//  hook; the clamp is applied imperatively on reader appear.
//
//  Fully `#if targetEnvironment(macCatalyst)`-gated: iOS keeps PDFKit's paged
//  layout and gets no window clamp.
//

#if targetEnvironment(macCatalyst)
import UIKit
import CoreGraphics

@MainActor
public enum PDFMacWindowSizing {
    /// Clamps every connected window scene's minimum content size so a page can
    /// never render below the minimum readable width. Reaches the scene via the
    /// established `connectedScenes` idiom (no `UIWindowSceneDelegate` exists).
    ///
    /// `minWidth` defaults to `PDFReaderLayoutMetrics.minPageWidth` so the floor
    /// can never desync from the resolver's breakpoint constant.
    ///
    /// Pitfall 9: `sizeRestrictions` is nil on some scene configurations — guard
    /// it. `max(...)` semantics mean the clamp only ever RAISES an existing
    /// minimum (never shrinks a larger one another part of the app may have set).
    public static func applyMinWindowWidth(
        _ minWidth: CGFloat = PDFReaderLayoutMetrics.minPageWidth,
        minHeight: CGFloat = PDFReaderLayoutMetrics.minWindowHeight
    ) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  let restrictions = windowScene.sizeRestrictions else { continue }
            restrictions.minimumSize = clampedMinimum(
                existing: restrictions.minimumSize,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }
    }

    /// Pure, testable clamp: returns the minimum size given an existing minimum,
    /// raising each dimension to at least the supplied floor (never shrinking).
    /// Lets a unit test lock the `max()` semantics without a live UIWindowScene.
    public static func clampedMinimum(
        existing: CGSize,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGSize {
        CGSize(
            width: max(existing.width, minWidth),
            height: max(existing.height, minHeight)
        )
    }
}
#endif
