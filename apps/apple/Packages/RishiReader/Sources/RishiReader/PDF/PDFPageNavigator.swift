import Foundation

/// Phase 34 Plan 34-02 (SRP P0) — the single source of truth for the PDF
/// reader's next/prev/clamp page-navigation state machine.
///
/// Before this extraction the identical `min/max` clamp → "clamp didn't move =
/// boundary hit, else advance + seek" block was duplicated THREE times inside
/// `PDFReaderScreen` (the tap `onTap` closure, the Mac `pageForward`
/// notification handler, and the Mac `pageBackward` handler). This type
/// collapses all three into one tested unit.
///
/// Split into two pieces:
///   - ``PDFPageNavigationDecision`` — the PURE, `nonisolated` value-type math
///     (clamp + boundary detection). Fully unit-testable off-device with no
///     PDFKit / UIKit / MainActor dependency.
///   - ``PDFPageNavigator`` — a `@MainActor` helper that applies a decision to
///     the live ``PDFReaderViewModel`` (boundary haptic vs. advance + seek),
///     preserving the exact side-effect ordering of the original inline blocks.
///
/// Behavior-preserving: `goNext()` / `goPrev()` reproduce the original call
/// sequences verbatim (`viewModel.hitBoundary()` on a no-move clamp, else
/// `viewModel.advancePage()` followed by `viewModel.seek(toPage:)`).

/// Pure outcome of a page-navigation request: either the clamp produced no
/// movement (a boundary hit) or the reader should advance to a new page.
public enum PDFPageNavigationDecision: Sendable, Equatable {
    /// The clamp did not change the page index — the user hit the first/last
    /// page boundary. Drives the warning sensory feedback.
    case hitBoundary
    /// The reader should move to `toPage` (already clamped to a valid index).
    /// Drives the page-turn impact haptic + position seek.
    case advance(toPage: Int)

    /// Pure next-page decision: clamps `current + 1` to `[0, max(total - 1, 0)]`
    /// and reports whether the clamp moved. Mirrors the original
    /// `min(pageIndex + 1, max(totalPages - 1, 0))` inline logic exactly.
    public static func next(current: Int, total: Int) -> PDFPageNavigationDecision {
        let clamped = min(current + 1, max(total - 1, 0))
        return clamped == current ? .hitBoundary : .advance(toPage: clamped)
    }

    /// Pure previous-page decision: clamps `current - 1` to `>= 0` and reports
    /// whether the clamp moved. Mirrors the original `max(pageIndex - 1, 0)`
    /// inline logic exactly.
    public static func previous(current: Int) -> PDFPageNavigationDecision {
        let clamped = max(current - 1, 0)
        return clamped == current ? .hitBoundary : .advance(toPage: clamped)
    }
}

/// `@MainActor` driver that resolves a page-navigation request against the live
/// view-model and applies the resulting side effect with the original ordering.
@MainActor
public struct PDFPageNavigator {
    private let viewModel: PDFReaderViewModel

    public init(viewModel: PDFReaderViewModel) {
        self.viewModel = viewModel
    }

    /// Advance one page forward (or fire the boundary haptic at the last page).
    public func goNext() {
        apply(.next(current: viewModel.pageIndex, total: viewModel.totalPages))
    }

    /// Advance one page backward (or fire the boundary haptic at the first page).
    public func goPrev() {
        apply(.previous(current: viewModel.pageIndex))
    }

    /// Applies a pure decision to the view-model, preserving the exact
    /// side-effect sequence of the original inline blocks.
    private func apply(_ decision: PDFPageNavigationDecision) {
        switch decision {
        case .hitBoundary:
            // Phase 18 Plan 18-02 — F-P1-01: clamp didn't move = boundary hit.
            // Drives `.sensoryFeedback(.warning, trigger: lastBoundaryHitTick)`.
            viewModel.hitBoundary()
        case .advance(let page):
            // Drives `.sensoryFeedback(.impact(.light), trigger: currentPageIndex)`.
            viewModel.advancePage()
            viewModel.seek(toPage: page)
        }
    }
}
