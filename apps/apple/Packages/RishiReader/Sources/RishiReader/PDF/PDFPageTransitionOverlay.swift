//
//  PDFPageTransitionOverlay.swift
//  RishiReader
//
//  Phase 30 plan 30-04 — directional snapshot-slide transition overlay for the
//  Mac PDF reader's Apple-Books-style page turn.
//
//  The whole feature is Mac Catalyst-only (the overscroll-to-turn gesture and
//  two-up spread paging that call this overlay live behind
//  `#if targetEnvironment(macCatalyst)` in PDFReaderView). iOS keeps its
//  `usePageViewController` paging untouched, so this file is gated top-to-bottom
//  and contributes nothing to the iOS build.
//
//  Approach (RESEARCH Pattern 3 "snapshot-slide overlay (~0.3s,
//  accessibilityReduceMotion-gated)"): snapshot the freshly-rendered PDFView,
//  slide the outgoing snapshot off toward the opposite edge while the new page
//  is revealed underneath, so the incoming page appears to enter from `edge`.
//  The overlay never fights PDFKit's page model — the real page is already
//  committed by the time this runs; the snapshot is a throwaway visual that is
//  removed on completion.
//

#if targetEnvironment(macCatalyst)
import UIKit
import PDFKit

/// Which side the INCOMING page enters from. `.fromTrailing` for a next-page /
/// next-spread turn, `.fromLeading` for a previous-page / previous-spread turn.
enum PDFPageTransitionEdge {
    case fromLeading
    case fromTrailing
}

@MainActor
enum PDFPageTransitionOverlay {
    /// Snapshots the current PDFView and slides the outgoing snapshot off toward
    /// the opposite edge while the freshly-rendered page is revealed underneath,
    /// so the incoming page appears to enter from `edge`. ~0.3s; skipped
    /// entirely when Reduce Motion is enabled (the page change has already been
    /// committed, so skipping the animation simply shows the new page instantly).
    static func run(
        on pdfView: PDFView,
        edge: PDFPageTransitionEdge,
        duration: TimeInterval = 0.3
    ) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        guard let snapshot = pdfView.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = pdfView.bounds
        pdfView.addSubview(snapshot)
        let width = pdfView.bounds.width
        // Incoming from trailing => outgoing slides toward leading (negative X),
        // and vice-versa, so the new page reads as entering from `edge`.
        let outgoingTranslation = (edge == .fromTrailing) ? -width : width
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                snapshot.transform = CGAffineTransform(translationX: outgoingTranslation, y: 0)
                snapshot.alpha = 0.0
            },
            completion: { _ in snapshot.removeFromSuperview() }
        )
    }
}
#endif
