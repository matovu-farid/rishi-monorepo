@testable import rishi
//
//  OverscrollEventReducerTests.swift
//  RishiReaderTests
//
//  Phase 34 plan 34-04 — locks the per-event Mode-A reducer extracted from the
//  Mac overscroll-to-turn state machine (formerly inline in
//  `PDFReaderView.Coordinator.handleOverscroll`).
//
//  `OverscrollEventReducer.reduce` is the cross-platform, `nonisolated` core that
//  turns one raw `(offsetY, lastOffsetY)` pair plus scroll geometry into the next
//  accumulator value + direction + decision. It carries NO UIKit/PDFKit types, so
//  these tests compile and run on iPhone 17 even though the KVO glue that drives it
//  is hard-gated to Mac Catalyst.
//
//  These tests pin the THRESHOLD (a turn only commits past the accumulated edge
//  overscroll), DIRECTION derivation (sign of the offset delta), and the
//  DEBOUNCE-adjacent direction-reset (Pitfall 4 — a reversal resets the
//  accumulator so a brief flick cannot reuse stale accumulation to trip a turn).
//

import Testing
import CoreGraphics


@Suite("OverscrollEventReducer")
struct OverscrollEventReducerTests {

    private let threshold: CGFloat = 60

    // MARK: - Direction derivation

    @Test("offset increase derives .down direction")
    func increasingOffsetIsDown() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 120,
            lastOffsetY: 100,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 0,
            lastDirection: .none,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.direction == .down)
    }

    @Test("offset decrease derives .up direction")
    func decreasingOffsetIsUp() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 80,
            lastOffsetY: 100,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 0,
            lastDirection: .none,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.direction == .up)
    }

    @Test("no offset change is a no-op: carries accumulator + last direction, decision .none")
    func zeroDeltaIsNoOp() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 100,
            lastOffsetY: 100,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 42,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.direction == .down)            // carried, not reset to .none
        #expect(r.accumulatedOverscroll == 42)   // unchanged
        #expect(r.decision == .none)
    }

    // MARK: - Threshold

    @Test("at bottom edge, accumulation crosses threshold this event -> .turnNext")
    func bottomEdgeCrossesThresholdTurnsNext() {
        // lastDirection matches so accumulate ADDS: 50 + 20 = 70 >= 60.
        // offsetY 1400 + viewport 600 == contentHeight 2000: exactly at bottom.
        let r = OverscrollEventReducer.reduce(
            offsetY: 1400,
            lastOffsetY: 1380,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 50,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.accumulatedOverscroll == 70)
        #expect(r.decision == .turnNext)
    }

    @Test("at bottom edge but accumulation still below threshold -> .none")
    func bottomEdgeBelowThresholdIsNone() {
        // 30 + 20 = 50 < 60.
        let r = OverscrollEventReducer.reduce(
            offsetY: 1400,
            lastOffsetY: 1380,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 30,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.accumulatedOverscroll == 50)
        #expect(r.decision == .none)
    }

    @Test("mid-page (not at an edge) never turns regardless of accumulation")
    func midPageNeverTurns() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 700,            // 700 + 600 = 1300 < 2000: mid-page
            lastOffsetY: 680,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 500,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.decision == .none)
    }

    // MARK: - Boundary

    @Test("at bottom edge past threshold but already last page -> .boundary")
    func bottomEdgeLastPageIsBoundary() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 1400,
            lastOffsetY: 1380,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 50,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: true,
            threshold: threshold
        )
        #expect(r.decision == .boundary)
    }

    @Test("at top edge past threshold, not first page -> .turnPrev")
    func topEdgePastThresholdTurnsPrev() {
        // Scrolling up: 0 - 20 derives .up; accumulate 50 + 20 = 70 >= 60.
        let r = OverscrollEventReducer.reduce(
            offsetY: 0,
            lastOffsetY: 20,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 50,
            lastDirection: .up,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.direction == .up)
        #expect(r.decision == .turnPrev)
    }

    @Test("at top edge past threshold but already first page -> .boundary")
    func topEdgeFirstPageIsBoundary() {
        let r = OverscrollEventReducer.reduce(
            offsetY: 0,
            lastOffsetY: 20,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 50,
            lastDirection: .up,
            isAtFirstPage: true,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.decision == .boundary)
    }

    // MARK: - Direction reset (Pitfall 4 anti-accidental-flip)

    @Test("a reversal RESETS the accumulator so a brief flick cannot trip a turn")
    func reversalResetsAccumulator() {
        // Large prior down-accumulation, but this event is UP (a flick the other
        // way). The accumulator must reset to abs(delta), not keep 500.
        let r = OverscrollEventReducer.reduce(
            offsetY: 0,
            lastOffsetY: 12,          // delta -12 -> .up, opposite of lastDirection .down
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 500,
            lastDirection: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(r.direction == .up)
        #expect(r.accumulatedOverscroll == 12)  // reset, not 512
        #expect(r.decision == .none)            // 12 < 60 threshold, no flip
    }
}
