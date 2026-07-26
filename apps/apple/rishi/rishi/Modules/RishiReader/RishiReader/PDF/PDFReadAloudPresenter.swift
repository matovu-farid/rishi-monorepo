#if canImport(UIKit)
import UIKit
import PDFKit
import CoreGraphics

/// Phase 34 Plan 34-02 (SRP P0) — owns the read-aloud inline-highlight +
/// Mac auto-scroll geometry that previously lived as `applyReadAloudHighlight`
/// inside the `PDFReaderScreen` `View` (plus the
/// `firstEnclosedScrollViewForAutoScroll` `PDFView` extension).
///
/// Resolves `readAloudParagraph` to a `PDFSelection` on the current page and
/// pushes it into `PDFView.highlightedSelections` so the spoken passage is
/// tinted without disturbing the user's own text selection. On Mac Catalyst it
/// additionally drives the auto-scroll offset math (Mode A) or ensures the
/// spoken page's spread is on screen (Modes B / Single Page).
///
/// `@MainActor` because it touches `PDFView` (UIKit). The offset math itself is
/// the pure ``ReadAloudScrollTarget`` (host-testable); this type is the UIKit
/// glue. Behavior-preserving: the highlight assignment + Mac switch reproduce
/// the original method verbatim.
@MainActor
public struct PDFReadAloudPresenter {

    public init() {}

    /// Applies (or clears) the read-aloud highlight for `paragraph` on
    /// `pdfView`'s current page, then runs Mac-gated auto-scroll for the
    /// resolved layout `mode`.
    public func apply(
        paragraph: String?,
        on pdfView: PDFView?,
        mode: PDFReaderLayoutMode
    ) {
        guard let pdfView else { return }
        guard let paragraph,
              let page = pdfView.currentPage,
              let selection = PDFReadAloudHighlighter.selection(in: page, paragraph: paragraph)
        else {
            pdfView.highlightedSelections = nil
            return
        }
        pdfView.highlightedSelections = [selection]

        // Phase 30 plan 30-05 — Mac-gated read-aloud auto-scroll. iOS keeps
        // PDFKit's paged mode and gets no auto-scroll. Mode A (single
        // fit-to-width) scrolls the spoken passage near the top of the
        // enclosed scroll view via the pure `ReadAloudScrollTarget` offset
        // math (plan 30-02). Mode B (two-up spread) has no within-page scroll,
        // so it only ensures the spoken page's spread is on screen.
        #if targetEnvironment(macCatalyst)
        switch mode {
        case .singleFitWidth:
            let rect = selection.bounds(for: page)
            if let scroll = Self.firstEnclosedScrollView(in: pdfView) {
                let viewRect = pdfView.convert(rect, from: page)
                let passageMinY = scroll.convert(viewRect, from: pdfView).minY
                var target = scroll.contentOffset
                target.y = ReadAloudScrollTarget.targetOffsetY(
                    passageMinY: passageMinY,
                    viewportHeight: scroll.bounds.height,
                    contentHeight: scroll.contentSize.height
                )
                // animated (Pitfall 6: go(to:) is not animated; setContentOffset is).
                scroll.setContentOffset(target, animated: true)
            } else {
                // Nil-safe fallback (Pitfall 3): no enclosed scroll view found.
                pdfView.go(to: rect, on: page)
            }
        case .twoUpSpread:
            // Two-up has no within-page scroll: just ensure the spoken page's
            // spread is on screen if it is currently off-spread.
            if let spokenPage = selection.pages.first, pdfView.currentPage !== spokenPage {
                pdfView.go(to: spokenPage)
            }
        case .singlePage:
            // Phase 31 — Single Page has no within-page vertical scroll; just
            // navigate to the spoken page (same as .twoUpSpread). PDFKit's
            // UIPageViewController handles the horizontal turn.
            if let spokenPage = selection.pages.first, pdfView.currentPage !== spokenPage {
                pdfView.go(to: spokenPage)
            }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// First `UIScrollView` descendant of `pdfView`, or nil — used by the
    /// Phase 30 read-aloud auto-scroll (Mode A) to drive the content offset.
    /// Pitfall 3: PDFKit's enclosed-scroll-view structure is NOT contractual,
    /// so this degrades gracefully and NEVER force-unwraps; a nil result falls
    /// back to `go(to:on:)` at the call site. Mirrors the private traversal in
    /// ``PDFReaderView`` (plan 30-04).
    private static func firstEnclosedScrollView(in pdfView: PDFView) -> UIScrollView? {
        func search(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        return search(pdfView)
    }
    #endif
}
#endif
