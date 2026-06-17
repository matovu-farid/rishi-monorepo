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

/// Which side the INCOMING page enters from.
/// - Horizontal (two-up spread paging): `.fromTrailing` next-spread,
///   `.fromLeading` previous-spread.
/// - Vertical (Continuous single-page overscroll-to-turn): `.fromBottom` the
///   next page enters from underneath (turn forward at the page bottom),
///   `.fromTop` the previous page enters from the top (turn back at the page top).
enum PDFPageTransitionEdge {
    case fromLeading
    case fromTrailing
    case fromTop
    case fromBottom
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
        let height = pdfView.bounds.height
        // The outgoing snapshot slides off toward the edge OPPOSITE to where the
        // incoming page reads as entering from, revealing the (already-committed)
        // new page underneath. Horizontal for spread paging; vertical for the
        // Continuous overscroll turn (next from the bottom, previous from the top).
        let outgoing: CGAffineTransform
        switch edge {
        case .fromTrailing: outgoing = CGAffineTransform(translationX: -width, y: 0)
        case .fromLeading:  outgoing = CGAffineTransform(translationX: width, y: 0)
        case .fromBottom:   outgoing = CGAffineTransform(translationX: 0, y: -height)
        case .fromTop:      outgoing = CGAffineTransform(translationX: 0, y: height)
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                snapshot.transform = outgoing
                snapshot.alpha = 0.0
            },
            completion: { _ in snapshot.removeFromSuperview() }
        )
    }
}
#endif
