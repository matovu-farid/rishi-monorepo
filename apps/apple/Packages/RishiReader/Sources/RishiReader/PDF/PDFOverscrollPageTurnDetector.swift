//
//  PDFOverscrollPageTurnDetector.swift
//  RishiReader
//
//  Phase 34 plan 34-04 — SRP extraction of the Mac overscroll-to-turn / spread
//  paging state machine out of `PDFReaderView.Coordinator`.
//
//  The Coordinator was a legitimate PDFKit `PDFViewDelegate` FUSED with a full
//  Mac overscroll-to-turn KVO state machine (7 mutable accumulator/observer
//  fields + a settle-debounce). This type owns that machine so the Coordinator
//  stays a thin delegate. Behavior is identical to the prior in-Coordinator
//  implementation.
//
//  The KVO/UIKit wiring (observer install, content-offset callback, settle
//  debounce, directional transition overlay) is hard-gated to Mac Catalyst via
//  `#if targetEnvironment(macCatalyst)` so iOS is byte-unaffected.
//
//  The pure decision math already lives in the cross-platform
//  ``OverscrollTurnDecider``. This file additionally exposes a SINGLE
//  cross-platform, `nonisolated` per-event reduction —
//  ``OverscrollEventReducer`` — that turns a raw `(offsetY, lastOffsetY)` pair
//  plus scroll geometry into the next accumulator value + a decision. That core
//  carries NO UIKit/PDFKit types (plain `CGFloat`/`Int`/enums) so it compiles
//  and is unit-tested on iPhone 17 even though the KVO glue below is Mac-only.
//

import CoreGraphics

/// Inputs and the resulting next-state for ONE Mode-A overscroll event. Pure,
/// cross-platform, `Sendable` — no UIKit/PDFKit, no `#if`.
public struct OverscrollEventResult: Sendable, Equatable {
    /// The accumulator value after folding this event in.
    public let accumulatedOverscroll: CGFloat
    /// The scroll direction derived from this event's delta.
    public let direction: ScrollDirection
    /// The committed turn decision for this event.
    public let decision: OverscrollTurnDecision
}

/// Pure, `nonisolated` Mode-A per-event reducer. Mirrors EXACTLY the sequence the
/// Mac KVO callback runs (`handleOverscroll`): derive direction + delta from the
/// offset pair, accumulate via ``OverscrollTurnDecider/accumulate(current:delta:direction:lastDirection:)``
/// (which resets on direction change — Pitfall 4), then decide via
/// ``OverscrollTurnDecider/decide(...)``. Extracted so the threshold / debounce /
/// direction behavior is unit-testable on any platform.
public enum OverscrollEventReducer {
    /// Folds one offset change into the accumulator and returns the resulting
    /// decision. A zero (`.none`) direction is a no-op: the accumulator and
    /// last-direction are carried through unchanged and the decision is `.none`
    /// (matching the live guard that early-returns before touching the decider).
    public static func reduce(
        offsetY: CGFloat,
        lastOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        accumulatedOverscroll: CGFloat,
        lastDirection: ScrollDirection,
        isAtFirstPage: Bool,
        isAtLastPage: Bool,
        threshold: CGFloat = OverscrollTurnDecider.defaultThreshold
    ) -> OverscrollEventResult {
        let delta = offsetY - lastOffsetY
        let direction: ScrollDirection = delta > 0 ? .down : (delta < 0 ? .up : .none)
        guard direction != .none else {
            return OverscrollEventResult(
                accumulatedOverscroll: accumulatedOverscroll,
                direction: lastDirection,
                decision: .none
            )
        }
        let nextAccumulated = OverscrollTurnDecider.accumulate(
            current: accumulatedOverscroll,
            delta: delta,
            direction: direction,
            lastDirection: lastDirection
        )
        let decision = OverscrollTurnDecider.decide(
            offsetY: offsetY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            accumulatedOverscroll: nextAccumulated,
            direction: direction,
            isAtFirstPage: isAtFirstPage,
            isAtLastPage: isAtLastPage,
            threshold: threshold
        )
        return OverscrollEventResult(
            accumulatedOverscroll: nextAccumulated,
            direction: direction,
            decision: decision
        )
    }
}

#if targetEnvironment(macCatalyst)
import UIKit
import PDFKit

/// Minimal seam the detector drives so the Mode-A decision flow is decoupled from
/// the concrete ``PDFReaderViewModel``. Mirrors the exact VM methods the original
/// in-Coordinator machine called.
@MainActor
protocol PDFPageTurnTarget: AnyObject {
    var pageIndex: Int { get }
    var totalPages: Int { get }
    func advancePage()
    func seek(toPage newIndex: Int)
    func hitBoundary()
}

extension PDFReaderViewModel: PDFPageTurnTarget {}

/// Mac-only overscroll-to-turn / spread paging state machine. Owns the KVO token,
/// the accumulator fields, the ``OverscrollTurnDecider`` driving, the settle
/// debounce, and the ``PDFPageTransitionOverlay`` calls. The Coordinator holds one
/// optional instance and installs it once PDFKit has built its enclosed scroller.
///
/// `appliedLayoutMode` is set by the Coordinator (it tracks the live Mac layout
/// mode) and selects Mode A (`.singleFitWidth`) vs Mode B (`.twoUpSpread`); every
/// other value is inert, matching the original strict switch.
@MainActor
final class PDFOverscrollPageTurnDetector {
    private let target: PDFPageTurnTarget

    /// Current Mac layout mode, mirrored from the Coordinator. Inert until set to
    /// `.singleFitWidth` (Mode A) or `.twoUpSpread` (Mode B).
    var appliedLayoutMode: PDFReaderLayoutMode?

    /// KVO token for the enclosed `UIScrollView`'s `contentOffset`. Stored so the
    /// observation lives as long as the detector and is torn down in `deinit`.
    /// Pitfall 5: we OBSERVE the offset — we never assign the scroll view's
    /// `.delegate`, which would fight PDFKit's own paging.
    private var contentOffsetObservation: NSKeyValueObservation?
    /// Weak ref to the live PDFView so the offset callback can commit turns and
    /// drive the directional slide overlay without retaining the view.
    private weak var observedPDFView: PDFView?
    /// Accumulated overscroll past the relevant edge (Mode A). Reset on a committed
    /// turn and on a scroll-direction change (the latter inside the reducer).
    private var accumulatedOverscroll: CGFloat = 0
    /// Previous vertical offset, used to derive the instantaneous scroll direction
    /// and per-event delta for the accumulator.
    private var lastOffsetY: CGFloat = 0
    /// Previous horizontal offset, used to derive a discrete Mode-B swipe direction
    /// (one swipe = one spread, no accumulator).
    private var lastOffsetX: CGFloat = 0
    /// Last scroll direction (Mode A) so the accumulator resets on reversal.
    private var lastDirection: ScrollDirection = .none
    /// Debounce flag: while a turn is settling we ignore offset callbacks so one
    /// overscroll past threshold commits EXACTLY one page/spread turn.
    private var isTurnSettling: Bool = false

    init(target: PDFPageTurnTarget) {
        self.target = target
    }

    deinit {
        contentOffsetObservation?.invalidate()
    }

    // MARK: - Scroll observation

    /// First `UIScrollView` descendant of the PDFView, or nil. Pitfall 3: the
    /// enclosed-scroll-view structure is NOT contractual, so this degrades
    /// gracefully — never force-unwraps. If no scroll view is found, no observer is
    /// installed and the gesture is simply absent (no crash, no behavior change).
    private func firstEnclosedScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let s = firstEnclosedScrollView(sub) { return s }
        }
        return nil
    }

    /// Installs the KVO observer on the PDFView's enclosed scroll view's
    /// `contentOffset` (Pitfall 5: observe, do NOT steal the delegate). Idempotent —
    /// a second call invalidates the prior token first so a re-realized scroll view
    /// never leaks an observer.
    func installScrollObserver(on pdfView: PDFView) {
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        observedPDFView = pdfView
        guard let scroll = firstEnclosedScrollView(pdfView) else { return }
        lastOffsetY = scroll.contentOffset.y
        lastOffsetX = scroll.contentOffset.x
        // `[.new]` only — the closure reads `scroll` directly. Capture the detector
        // weakly and hop to the MainActor (the detector is @MainActor) so the offset
        // callback can touch the VM safely.
        contentOffsetObservation = scroll.observe(
            \.contentOffset,
            options: [.new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                self?.handleContentOffsetChange(scrollView)
            }
        }
    }

    /// Routes an offset change to Mode A (overscroll accumulator + decider) or
    /// Mode B (one discrete swipe = one spread). Mode B is selected when the applied
    /// layout mode is `.twoUpSpread`; everything else is Mode A.
    private func handleContentOffsetChange(_ scroll: UIScrollView) {
        guard !isTurnSettling else { return }
        // Phase 31 — strict, exhaustive switch (no `default:`) so the compiler forces
        // a decision for every effective mode. Single Page is INERT: PDFKit's
        // UIPageViewController owns horizontal turns and the directional-transition
        // overlay (driven only from handleOverscroll/handleSpreadSwipe) is therefore
        // never triggered there — correct, since PDFKit provides its own native
        // horizontal transition (Pitfall 2). Two Page + Continuous unchanged.
        switch appliedLayoutMode {
        case .singleFitWidth?:
            handleOverscroll(scroll)
        case .twoUpSpread?:
            handleSpreadSwipe(scroll)
        case .singlePage?:
            return
        case nil:
            return
        }
    }

    /// Mode A — feed geometry into ``OverscrollEventReducer`` and commit a turn once
    /// accumulated overscroll past the edge crosses the threshold.
    private func handleOverscroll(_ scroll: UIScrollView) {
        let result = OverscrollEventReducer.reduce(
            offsetY: scroll.contentOffset.y,
            lastOffsetY: lastOffsetY,
            contentHeight: scroll.contentSize.height,
            viewportHeight: scroll.bounds.height,
            accumulatedOverscroll: accumulatedOverscroll,
            lastDirection: lastDirection,
            isAtFirstPage: target.pageIndex <= 0,
            isAtLastPage: target.pageIndex >= target.totalPages - 1
        )
        // No vertical movement — carry offset forward, nothing to decide.
        guard result.direction != .none else {
            lastOffsetY = scroll.contentOffset.y
            return
        }
        accumulatedOverscroll = result.accumulatedOverscroll
        lastDirection = result.direction
        lastOffsetY = scroll.contentOffset.y

        switch result.decision {
        case .turnNext:
            let next = min(target.pageIndex + 1, max(target.totalPages - 1, 0))
            target.advancePage()
            target.seek(toPage: next)
            // A forward turn commits from the BOTTOM of the page, so the enclosed
            // scroll view's offset is near-max. PDFKit's page swap (go(to:)) preserves
            // that offset, which would land the new page on its bottom; pin it to top.
            resetAccumulator(landAtTop: true)
            // Continuous turns are vertical: forward at the page bottom, the next page
            // enters from underneath (bottom).
            runTransition(.fromBottom)
        case .turnPrev:
            let prev = max(target.pageIndex - 1, 0)
            target.advancePage()
            target.seek(toPage: prev)
            resetAccumulator()
            // ...and back at the page top, the previous page enters from the top.
            runTransition(.fromTop)
        case .boundary:
            target.hitBoundary()
            resetAccumulator()
        case .none:
            break
        }
    }

    /// Mode B — a single discrete horizontal scroll/swipe turns exactly one spread
    /// via `goToNextPage`/`goToPreviousPage` (no accumulator). The existing
    /// `.PDFViewPageChanged` loop keeps the VM in sync afterward.
    private func handleSpreadSwipe(_ scroll: UIScrollView) {
        let offsetX = scroll.contentOffset.x
        let deltaX = offsetX - lastOffsetX
        lastOffsetX = offsetX
        // Ignore sub-pixel jitter; a real swipe moves several points.
        guard abs(deltaX) >= 1 else { return }
        guard let pdfView = observedPDFView else { return }
        if deltaX > 0 {
            pdfView.goToNextPage(nil)
            runTransition(.fromTrailing)
        } else {
            pdfView.goToPreviousPage(nil)
            runTransition(.fromLeading)
        }
        // Debounce: one discrete swipe = one spread. Settle before the next.
        beginTurnSettling()
    }

    /// Resets the Mode-A accumulator and begins the settle debounce so the committed
    /// turn lands before any further offset callback is honored.
    private func resetAccumulator(landAtTop: Bool = false) {
        accumulatedOverscroll = 0
        lastDirection = .none
        beginTurnSettling(landAtTop: landAtTop)
    }

    /// Briefly ignores offset callbacks so the new page/spread settles and one
    /// overscroll/swipe commits exactly one turn (Pitfall 4 — no accidental
    /// multi-flips). Re-syncs `lastOffsetY/X` to the settled position on resume so
    /// the next delta is measured cleanly.
    private func beginTurnSettling(landAtTop: Bool = false) {
        isTurnSettling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let scroll = self.observedPDFView.flatMap({ self.firstEnclosedScrollView($0) }) {
                // After a forward (.singleFitWidth) turn the swapped-in page inherits
                // the previous page's near-bottom offset; force it to the top so the
                // new page opens at its top, not its bottom. Runs while isTurnSettling
                // is true, so the KVO observer ignores this programmatic write (no
                // spurious reverse turn).
                if landAtTop {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 0), animated: false)
                }
                self.lastOffsetY = scroll.contentOffset.y
                self.lastOffsetX = scroll.contentOffset.x
            }
            self.isTurnSettling = false
        }
    }

    /// Runs the directional snapshot-slide overlay (plan 30-04 Task 2) on the live
    /// PDFView, showing which side the incoming page enters from. No-op when the
    /// PDFView is gone or Reduce Motion is on (the overlay itself honors the
    /// accessibility setting).
    private func runTransition(_ edge: PDFPageTransitionEdge) {
        guard let pdfView = observedPDFView else { return }
        PDFPageTransitionOverlay.run(on: pdfView, edge: edge)
    }
}
#endif
