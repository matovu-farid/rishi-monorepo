import Testing
import Foundation
@testable import RishiReader

/// Pure-logic tests for the gesture-decision struct that decides whether
/// a drag should commit a page turn, snap back to the current page, or
/// register a boundary bounce.
///
/// The struct takes translation + velocity + boundary metadata and
/// returns one of three outcomes. No SwiftUI involved — these tests run
/// without spinning views or simulating touches.
@Suite("PageTurnGestureResolver")
struct PageTurnGestureResolverTests {

    private let pageWidth: CGFloat = 400

    // MARK: - Velocity

    @Test("Commits forward on fast leftward swipe (velocity > 800)")
    func PageTurnVelocity_CommitsOnFastSwipe() {
        let resolver = PageTurnGestureResolver(
            pageWidth: pageWidth,
            commitFraction: 0.4,
            commitVelocity: 800
        )

        // Short translation but high velocity — should still commit.
        let decision = resolver.decide(
            translation: -80,
            velocity: -1200,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: false
        )

        #expect(decision == .commitNext)
    }

    @Test("Commits backward on fast rightward swipe")
    func PageTurnVelocity_CommitsBackwardOnFastSwipe() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        let decision = resolver.decide(
            translation: 60,
            velocity: 1500,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: false
        )

        #expect(decision == .commitPrevious)
    }

    @Test("Snaps back on short slow drag")
    func PageTurnVelocity_SnapsBackOnSlowShortDrag() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        // 20% of width, low velocity — neither fraction nor velocity
        // threshold is met.
        let decision = resolver.decide(
            translation: -pageWidth * 0.2,
            velocity: -120,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: false
        )

        #expect(decision == .snapBack)
    }

    @Test("Commits forward when dragged past 40% threshold")
    func PageTurnFraction_CommitsAtFractionThreshold() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        // Just over 40% of width, slow release — fraction wins.
        let decision = resolver.decide(
            translation: -pageWidth * 0.42,
            velocity: -50,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: false
        )

        #expect(decision == .commitNext)
    }

    // MARK: - Boundary

    @Test("Does not advance past the last page; returns boundary bounce")
    func BoundaryBounce_DoesNotAdvancePastLastPage() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        let decision = resolver.decide(
            translation: -pageWidth * 0.9,
            velocity: -2000,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: true
        )

        #expect(decision == .boundaryBounce)
    }

    @Test("Does not advance past the first page; returns boundary bounce")
    func BoundaryBounce_DoesNotGoBeforeFirstPage() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        let decision = resolver.decide(
            translation: pageWidth * 0.9,
            velocity: 2000,
            isAtLeadingBoundary: true,
            isAtTrailingBoundary: false
        )

        #expect(decision == .boundaryBounce)
    }

    @Test("Boundary direction does not block the opposite direction")
    func BoundaryBounce_AllowsOppositeDirection() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        // At last page, dragging backward (positive translation) should
        // still be permitted.
        let decision = resolver.decide(
            translation: pageWidth * 0.6,
            velocity: 50,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: true
        )

        #expect(decision == .commitPrevious)
    }

    // MARK: - Rubber-band

    @Test("Rubber-band damps drag past leading boundary")
    func RubberBand_ResistsLeadingBoundary() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        let raw: CGFloat = 200
        let damped = resolver.rubberBandedTranslation(
            raw: raw,
            isAtLeadingBoundary: true,
            isAtTrailingBoundary: false
        )

        #expect(damped < raw)
        #expect(damped > 0)
    }

    @Test("Rubber-band damps drag past trailing boundary")
    func RubberBand_ResistsTrailingBoundary() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        let raw: CGFloat = -200
        let damped = resolver.rubberBandedTranslation(
            raw: raw,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: true
        )

        #expect(damped > raw) // less negative
        #expect(damped < 0)
    }

    @Test("Rubber-band leaves valid drag unmodified")
    func RubberBand_PassesThroughValidDrag() {
        let resolver = PageTurnGestureResolver(pageWidth: pageWidth)

        // Dragging forward (negative) from a middle page is allowed.
        let raw: CGFloat = -100
        let damped = resolver.rubberBandedTranslation(
            raw: raw,
            isAtLeadingBoundary: false,
            isAtTrailingBoundary: false
        )

        #expect(damped == raw)
    }
}
