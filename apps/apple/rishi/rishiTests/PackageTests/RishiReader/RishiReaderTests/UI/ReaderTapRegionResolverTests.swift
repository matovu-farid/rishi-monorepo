@testable import rishi
import Testing
import Foundation
import CoreGraphics


/// Tests for the pure tap-region resolver that maps a tap point to one of
/// three decisions: previous page, toggle chrome, or next page.
///
/// Boundary semantics (matches Apple Books "wide center band" feel):
///   - x in [0, 0.25 * width)      -> .previousPage
///   - x in [0.25 * width, 0.75 * width] -> .toggleChrome (BOTH edges inclusive)
///   - x in (0.75 * width, width]  -> .nextPage
///
/// The resolver is pure / `Sendable` so the suite is not `@MainActor`.
@Suite("ReaderTapRegionResolver")
struct ReaderTapRegionResolverTests {

    private let size = CGSize(width: 400, height: 800)
    private let resolver = ReaderTapRegionResolver()

    @Test("Tap at x=0 routes to previousPage")
    func tapAtLeadingEdgeIsPreviousPage() {
        let decision = resolver.decide(at: CGPoint(x: 0, y: 400), in: size)
        #expect(decision == .previousPage)
    }

    @Test("Tap at x=10% width routes to previousPage")
    func tapAt10PercentIsPreviousPage() {
        let decision = resolver.decide(at: CGPoint(x: size.width * 0.10, y: 100), in: size)
        #expect(decision == .previousPage)
    }

    @Test("Tap at x=25% width routes to toggleChrome (inclusive boundary)")
    func tapAt25PercentIsToggleChrome() {
        let decision = resolver.decide(at: CGPoint(x: size.width * 0.25, y: 400), in: size)
        #expect(decision == .toggleChrome)
    }

    @Test("Tap at x=50% width routes to toggleChrome")
    func tapAt50PercentIsToggleChrome() {
        let decision = resolver.decide(at: CGPoint(x: size.width * 0.50, y: 400), in: size)
        #expect(decision == .toggleChrome)
    }

    @Test("Tap at x=75% width routes to toggleChrome (inclusive boundary)")
    func tapAt75PercentIsToggleChrome() {
        let decision = resolver.decide(at: CGPoint(x: size.width * 0.75, y: 400), in: size)
        #expect(decision == .toggleChrome)
    }

    @Test("Tap at x=90% width routes to nextPage")
    func tapAt90PercentIsNextPage() {
        let decision = resolver.decide(at: CGPoint(x: size.width * 0.90, y: 700), in: size)
        #expect(decision == .nextPage)
    }

    @Test("Tap at x=width routes to nextPage")
    func tapAtTrailingEdgeIsNextPage() {
        let decision = resolver.decide(at: CGPoint(x: size.width, y: 400), in: size)
        #expect(decision == .nextPage)
    }

    @Test("Disabled page navigation ignores the left and right regions")
    func disabledPageNavigationIgnoresEdgeRegions() {
        #expect(
            resolver.decide(
                at: CGPoint(x: size.width * 0.10, y: 400),
                in: size,
                allowsPageNavigation: false
            ) == .ignored
        )
        #expect(
            resolver.decide(
                at: CGPoint(x: size.width * 0.90, y: 400),
                in: size,
                allowsPageNavigation: false
            ) == .ignored
        )
    }

    @Test("Disabled page navigation keeps the center tap as chrome toggle")
    func disabledPageNavigationPreservesCenterToggle() {
        let decision = resolver.decide(
            at: CGPoint(x: size.width * 0.50, y: 400),
            in: size,
            allowsPageNavigation: false
        )
        #expect(decision == .toggleChrome)
    }

    @Test("Degenerate zero-width size returns toggleChrome")
    func degenerateZeroWidthReturnsToggleChrome() {
        let decision = resolver.decide(
            at: CGPoint(x: 0, y: 0),
            in: CGSize(width: 0, height: 0)
        )
        #expect(decision == .toggleChrome)
    }

    @Test("Vertical y does not change the decision")
    func verticalYIsIgnored() {
        // Edge tap at varying y should still resolve to .previousPage.
        let top = resolver.decide(at: CGPoint(x: 10, y: 0), in: size)
        let middle = resolver.decide(at: CGPoint(x: 10, y: size.height / 2), in: size)
        let bottom = resolver.decide(at: CGPoint(x: 10, y: size.height), in: size)
        #expect(top == .previousPage)
        #expect(middle == .previousPage)
        #expect(bottom == .previousPage)

        // Center tap at varying y should still resolve to .toggleChrome.
        let centerTop = resolver.decide(at: CGPoint(x: size.width / 2, y: 0), in: size)
        let centerBottom = resolver.decide(at: CGPoint(x: size.width / 2, y: size.height), in: size)
        #expect(centerTop == .toggleChrome)
        #expect(centerBottom == .toggleChrome)

        // Trailing tap at varying y should still resolve to .nextPage.
        let rightTop = resolver.decide(at: CGPoint(x: size.width - 10, y: 0), in: size)
        let rightBottom = resolver.decide(at: CGPoint(x: size.width - 10, y: size.height), in: size)
        #expect(rightTop == .nextPage)
        #expect(rightBottom == .nextPage)
    }
}
