//
//  OverscrollTurnDecider.swift
//  RishiReader
//
//  Pure Mode-A overscroll-to-turn decision core (Phase 30).
//
//  Given the enclosed scroll view's geometry (vertical offset, content height,
//  viewport height), an accumulated-overscroll value, the current scroll
//  direction, and the document-edge flags, this decides whether a page turn
//  should commit (.turnNext / .turnPrev), do nothing (.none), or report a
//  document boundary (.boundary).
//
//  This type is deliberately PURE: no UIKit, no PDFKit, no
//  `#if targetEnvironment(macCatalyst)`. It mirrors the AdvanceWatcherDecision
//  precedent so the genuinely-new Apple-Books overscroll-to-turn behavior has a
//  unit-testable decision core. The tiny UIKit glue (KVO on the scroll view's
//  contentOffset, calling decide(...) from the observer) lives in plan 30-04.
//
//  Pitfall 4 (accidental flips): the accumulator RESETS on direction change so a
//  brief flick in the opposite direction cannot reuse stale accumulation to trip
//  a turn. A turn only commits once accumulated overscroll past the relevant edge
//  exceeds `threshold`.
//

import CoreGraphics

public enum ScrollDirection: Sendable, Equatable {
    case up
    case down
    case none
}

public enum OverscrollTurnDecision: Sendable, Equatable {
    case none
    case turnNext
    case turnPrev
    /// At the relevant document edge + overscrolled past threshold, but no
    /// further page exists in that direction.
    case boundary
}

public enum OverscrollTurnDecider {
    /// Default anti-accidental-flip threshold (points of overscroll past the
    /// page edge before a turn commits).
    public static let defaultThreshold: CGFloat = 60

    /// Pure. No UIKit/PDFKit. Decides whether a page turn should commit given the
    /// enclosed scroll view's geometry and the accumulated overscroll past the
    /// relevant edge.
    ///
    /// - down: only when at the bottom edge (offsetY + viewportHeight >=
    ///   contentHeight) AND accumulatedOverscroll >= threshold. Returns
    ///   .boundary when already on the last page, otherwise .turnNext.
    /// - up: only when at the top edge (offsetY <= 0) AND accumulatedOverscroll
    ///   >= threshold. Returns .boundary when already on the first page,
    ///   otherwise .turnPrev.
    /// - none: always .none.
    public static func decide(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        accumulatedOverscroll: CGFloat,
        direction: ScrollDirection,
        isAtFirstPage: Bool,
        isAtLastPage: Bool,
        threshold: CGFloat = defaultThreshold
    ) -> OverscrollTurnDecision {
        switch direction {
        case .down:
            let atBottom = offsetY + viewportHeight >= contentHeight - 0.5
            guard atBottom, accumulatedOverscroll >= threshold else { return .none }
            return isAtLastPage ? .boundary : .turnNext
        case .up:
            let atTop = offsetY <= 0.5
            guard atTop, accumulatedOverscroll >= threshold else { return .none }
            return isAtFirstPage ? .boundary : .turnPrev
        case .none:
            return .none
        }
    }

    /// Pure accumulator. Adds the magnitude of `delta` while the scroll direction
    /// is unchanged; RESETS to the magnitude of `delta` the moment the direction
    /// changes (anti-accidental-flip, Pitfall 4).
    public static func accumulate(
        current: CGFloat,
        delta: CGFloat,
        direction: ScrollDirection,
        lastDirection: ScrollDirection
    ) -> CGFloat {
        direction == lastDirection ? current + abs(delta) : abs(delta)
    }
}
