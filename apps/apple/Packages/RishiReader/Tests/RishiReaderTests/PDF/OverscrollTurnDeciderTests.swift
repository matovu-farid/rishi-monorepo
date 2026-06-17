//
//  OverscrollTurnDeciderTests.swift
//  RishiReaderTests
//
//  Locks the pure Mode-A overscroll-to-turn decision core (Phase 30, plan 30-02).
//  Modeled on AdvanceWatcherDecisionTests: a pure decision fed plain inputs,
//  asserted with Swift Testing, no live PDFView/UIScrollView.
//
//  The decider turns the enclosed scroll view's geometry (offset, content size,
//  viewport height), an accumulated-overscroll value, the scroll direction, and
//  the document-edge flags into a page-turn decision. The anti-accidental-flip
//  threshold + direction-reset accumulator (Pitfall 4) are the genuinely-new
//  Mode-A logic these tests pin down.
//

import Testing
import CoreGraphics
@testable import RishiReader

@Suite("OverscrollTurnDecider")
struct OverscrollTurnDeciderTests {

    private let threshold: CGFloat = 60

    // MARK: - Scrolling DOWN

    @Test("down, not at bottom edge -> .none regardless of accumulation")
    func downNotAtBottomIsNone() {
        // offsetY + viewportHeight (200 + 600 = 800) < contentHeight (2000): mid-page.
        let decision = OverscrollTurnDecider.decide(
            offsetY: 200,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 500,   // well past threshold, but not at edge
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .none)
    }

    @Test("down, at bottom edge, accumulation < threshold -> .none")
    func downAtBottomBelowThresholdIsNone() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,          // 1400 + 600 == 2000: exactly at bottom
            accumulatedOverscroll: 30,    // below 60 threshold
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .none)
    }

    @Test("down, at bottom edge, accumulation >= threshold, not last page -> .turnNext")
    func downAtBottomPastThresholdTurnsNext() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 80,    // >= 60
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .turnNext)
    }

    @Test("down, at bottom edge, accumulation >= threshold, IS last page -> .boundary")
    func downAtBottomLastPageIsBoundary() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 80,
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: true,
            threshold: threshold
        )
        #expect(decision == .boundary)
    }

    // MARK: - Scrolling UP

    @Test("up, at top edge, accumulation >= threshold, not first page -> .turnPrev")
    func upAtTopPastThresholdTurnsPrev() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 0,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 75,
            direction: .up,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .turnPrev)
    }

    @Test("up, at top edge, accumulation >= threshold, IS first page -> .boundary")
    func upAtTopFirstPageIsBoundary() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 0,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 75,
            direction: .up,
            isAtFirstPage: true,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .boundary)
    }

    @Test("up, at top edge, accumulation < threshold -> .none")
    func upAtTopBelowThresholdIsNone() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 0,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 20,
            direction: .up,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .none)
    }

    @Test("up, not at top edge -> .none regardless of accumulation")
    func upNotAtTopIsNone() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 500,                 // mid-page, not at top
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 999,
            direction: .up,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .none)
    }

    @Test("direction .none -> .none")
    func directionNoneIsNone() {
        let decision = OverscrollTurnDecider.decide(
            offsetY: 0,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: 999,
            direction: .none,
            isAtFirstPage: false,
            isAtLastPage: false,
            threshold: threshold
        )
        #expect(decision == .none)
    }

    // MARK: - Accumulator (Pitfall 4: reset on direction change)

    @Test("accumulate ADDS when direction matches lastDirection")
    func accumulateAddsSameDirection() {
        let next = OverscrollTurnDecider.accumulate(
            current: 40,
            delta: 25,
            direction: .down,
            lastDirection: .down
        )
        #expect(next == 65)
    }

    @Test("accumulate uses abs(delta) so a same-direction negative delta still adds magnitude")
    func accumulateUsesMagnitude() {
        let next = OverscrollTurnDecider.accumulate(
            current: 40,
            delta: -25,
            direction: .up,
            lastDirection: .up
        )
        #expect(next == 65)
    }

    @Test("accumulate RESETS to abs(delta) when direction changes (anti-accidental-flip)")
    func accumulateResetsOnDirectionChange() {
        let next = OverscrollTurnDecider.accumulate(
            current: 500,                 // large prior accumulation in the old direction
            delta: 12,
            direction: .down,
            lastDirection: .up            // direction flipped
        )
        #expect(next == 12)               // reset, not 512
    }
}
