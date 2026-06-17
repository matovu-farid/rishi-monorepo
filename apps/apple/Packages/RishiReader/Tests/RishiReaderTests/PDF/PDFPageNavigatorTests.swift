import Testing
@testable import RishiReader

/// Phase 34 Plan 34-02 (SRP P0) — behavior tests for the extracted PDF page
/// navigation state machine. Before extraction this clamp/boundary logic was
/// duplicated 3x inside `PDFReaderScreen` and only smoke-covered; the pure
/// ``PDFPageNavigationDecision`` is now unit-testable off-device.
@Suite("PDFPageNavigationDecision")
struct PDFPageNavigatorTests {

    // MARK: next

    @Test("next advances when not at the last page")
    func nextAdvancesMidDocument() {
        #expect(PDFPageNavigationDecision.next(current: 0, total: 10) == .advance(toPage: 1))
        #expect(PDFPageNavigationDecision.next(current: 5, total: 10) == .advance(toPage: 6))
        #expect(PDFPageNavigationDecision.next(current: 8, total: 10) == .advance(toPage: 9))
    }

    @Test("next hits boundary at the last page")
    func nextHitsBoundaryAtLastPage() {
        #expect(PDFPageNavigationDecision.next(current: 9, total: 10) == .hitBoundary)
    }

    @Test("next on a single-page document is always a boundary hit")
    func nextSinglePageBoundary() {
        #expect(PDFPageNavigationDecision.next(current: 0, total: 1) == .hitBoundary)
    }

    @Test("next on an empty document clamps to boundary, never negative")
    func nextEmptyDocument() {
        // total == 0 -> max(total - 1, 0) == 0, so current 0 stays 0 -> boundary.
        #expect(PDFPageNavigationDecision.next(current: 0, total: 0) == .hitBoundary)
    }

    // MARK: previous

    @Test("previous advances when not at the first page")
    func previousAdvancesMidDocument() {
        #expect(PDFPageNavigationDecision.previous(current: 1) == .advance(toPage: 0))
        #expect(PDFPageNavigationDecision.previous(current: 9) == .advance(toPage: 8))
    }

    @Test("previous hits boundary at the first page")
    func previousHitsBoundaryAtFirstPage() {
        #expect(PDFPageNavigationDecision.previous(current: 0) == .hitBoundary)
    }

    // MARK: round-trip / symmetry

    @Test("next then previous returns to the original page mid-document")
    func nextThenPreviousRoundTrips() {
        let start = 4
        guard case .advance(let afterNext) = PDFPageNavigationDecision.next(current: start, total: 10) else {
            Issue.record("expected advance")
            return
        }
        guard case .advance(let afterPrev) = PDFPageNavigationDecision.previous(current: afterNext) else {
            Issue.record("expected advance")
            return
        }
        #expect(afterPrev == start)
    }
}
