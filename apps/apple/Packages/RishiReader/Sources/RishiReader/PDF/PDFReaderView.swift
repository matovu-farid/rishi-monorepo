import SwiftUI
import PDFKit
import RishiUIKit

#if canImport(UIKit)
import UIKit

/// SwiftUI wrapper around `PDFView` in paginated mode.
///
/// PITFALLS Pitfall 5: `usePageViewController(true, withViewOptions: nil)`
/// is mandatory. Without it `PDFView` rasterizes tiles for every visited
/// page and large PDFs (>200 MB) jetsam-kill the app on iPad mini and
/// older iPhones. Paginated mode also dodges the iOS 26
/// `PDFPageAnalyzerV2` recursive-lock regression.
///
/// **Highlight wiring (plan 05-06):** the view exposes two optional
/// callbacks consumed by ``PDFReaderScreen``:
///   - `onSelectionChange` fires on `.PDFViewSelectionChanged` with the
///     current `PDFSelection?`. The screen converts it into a
///     ``PDFHighlightLocator`` via ``PDFSelectionCoordinator`` and shows
///     the context menu.
///   - `onPDFViewReady` fires once with the live `PDFView` so the screen
///     can build a `mapRect` closure
///     (`pdfView.convert(_:to: pdfView.currentPage)`) for the overlay.
public struct PDFReaderView: UIViewRepresentable {

    public let viewModel: PDFReaderViewModel
    /// Phase 30 — resolved Mac layout mode driven by
    /// ``PDFReaderLayoutResolver`` from ``PDFReaderScreen``'s live
    /// `readerAreaSize`. It only changes behavior inside the
    /// `#if targetEnvironment(macCatalyst)` branches below — the iOS path
    /// never reads it, so iOS rendering is byte-identical regardless of the
    /// value. Defaults to `.singleFitWidth` so any non-Mac caller compiles
    /// unchanged.
    public var layoutMode: PDFReaderLayoutMode
    public var onSelectionChange: (PDFSelection?) -> Void
    public var onPDFViewReady: (PDFView) -> Void
    /// Phase 21 — single-tap callback driven by a UIKit
    /// `UITapGestureRecognizer` attached directly to the `PDFView` with
    /// `cancelsTouchesInView = false`. Replaces the SwiftUI
    /// `Color.clear.contentShape(Rectangle()).simultaneousGesture(...)`
    /// overlay that previously sat above the PDF; on iOS 26 that
    /// overlay's hit-test region intercepted pan touches, blocking
    /// PDFKit's `UIPageViewController` from receiving the swipe and
    /// leaving the user unable to turn the page. The UIKit recognizer
    /// only fires on a discrete tap; with `cancelsTouchesInView = false`
    /// the pan stream still reaches PDFKit.
    ///
    /// `point` is in `PDFView`'s coordinate space.
    public var onTap: (CGPoint) -> Void

    public init(
        viewModel: PDFReaderViewModel,
        layoutMode: PDFReaderLayoutMode = .singleFitWidth,
        onSelectionChange: @escaping (PDFSelection?) -> Void = { _ in },
        onPDFViewReady: @escaping (PDFView) -> Void = { _ in },
        onTap: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.layoutMode = layoutMode
        self.onSelectionChange = onSelectionChange
        self.onPDFViewReady = onPDFViewReady
        self.onTap = onTap
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            viewModel: viewModel,
            onSelectionChange: onSelectionChange,
            onTap: onTap
        )
    }

    public func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        #if targetEnvironment(macCatalyst)
        // Phase 30 — Mac uses the two-mode layout system (Mode A single
        // fit-to-width vertical scroll; Mode B two-up spread). CRITICAL:
        // Mac NEVER calls usePageViewController — it forces single-page
        // continuous and ignores displayMode (RESEARCH Pitfall 1/7), which
        // both breaks fit-to-width and prevents `.twoUp` from rendering.
        configureMacLayout(pdfView, mode: layoutMode)
        #else
        // iOS path — UNCHANGED, byte-identical to the prior block.
        // MUST be first: switches PDFView's internal scroller to a UIPageViewController.
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 4.0
        #endif
        pdfView.backgroundColor = .clear
        pdfView.delegate = context.coordinator
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pdfViewPageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pdfViewSelectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
        // Phase 21 — single-tap recognizer attached directly to the
        // PDFView with `cancelsTouchesInView = false` so PDFKit's
        // internal pan recognizer still receives the touch stream and
        // drives horizontal paging.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleContainerTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        tap.delegate = context.coordinator
        pdfView.addGestureRecognizer(tap)
        // Hand the live PDFView up to the screen so it can build the
        // rect-mapping closure for the highlight overlay. Defer until the
        // next main-loop tick so the screen's @State is allowed to mutate.
        let ready = onPDFViewReady
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            ready(pdfView)
            #if targetEnvironment(macCatalyst)
            // Phase 30 plan 30-04 — install the Mac-only enclosed-scroll-view
            // observer once the PDFView has built its internal scroller. The
            // observer drives Mode A overscroll-to-turn + Mode B spread paging;
            // iOS never reaches this branch so its paging path is untouched.
            coordinator.installScrollObserver(on: pdfView)
            #endif
        }
        return pdfView
    }

    #if targetEnvironment(macCatalyst)
    /// Mac-only per-mode `PDFView` configuration. The fit-to-width (Mode A)
    /// and two-up (Mode B) cases NEVER call `usePageViewController` (RESEARCH
    /// Pitfall 1/7: it ignores `displayMode` and disables fit). Phase 31's
    /// Single Page case DOES call it (it restores the pre-Phase-30 horizontal
    /// page-turn config) — because that toggle is sticky, transitions
    /// into/out of Single Page rebuild the `PDFView` rather than reconfigure
    /// in place (see updateUIView). Mode A = single fit-to-width with vertical
    /// scrolling; Mode B = two-up height-fit spread; Single Page = one page,
    /// horizontal page-turn.
    private func configureMacLayout(_ pdfView: PDFView, mode: PDFReaderLayoutMode) {
        switch mode {
        case .singlePage:
            // Phase 31 — restore the pre-Phase-30 Mac config (it IS the iOS
            // `#else` block): one page at a time, horizontal page-turns, whole
            // page fit. usePageViewController(true) MUST be first; it is a
            // sticky one-way scroller swap (Pitfall 1) — switching into/out of
            // this mode on a live PDFView is handled by the rebuild path in
            // updateUIView, NOT an in-place reconfigure.
            pdfView.usePageViewController(true, withViewOptions: nil)
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.autoScales = true
            pdfView.minScaleFactor = 0.5
            pdfView.maxScaleFactor = 4.0
        case .singleFitWidth:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.autoScales = true
            pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit
            pdfView.maxScaleFactor = 4.0
        case .twoUpSpread:
            pdfView.displayMode = .twoUp
            pdfView.displaysAsBook = true
            pdfView.displayDirection = .horizontal
            pdfView.autoScales = true
            pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit
            pdfView.maxScaleFactor = 4.0
        }
    }
    #endif

    public func updateUIView(_ uiView: PDFView, context: Context) {
        // Keep the coordinator's closure reference in sync with SwiftUI
        // state diffing — the parent may pass a new closure across re-renders.
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onTap = onTap

        // Wire the document (and re-wire when load() resolves).
        if uiView.document !== viewModel.document {
            uiView.document = viewModel.document
        }
        // Seek to the model's page when it diverges from PDFView's current page.
        if let doc = viewModel.document,
           let target = doc.page(at: viewModel.pageIndex),
           uiView.currentPage !== target {
            uiView.go(to: target)
        }
        uiView.backgroundColor = themeBackground(viewModel.theme)

        #if targetEnvironment(macCatalyst)
        // Re-apply layout if the resolved mode changed across a re-render
        // (live resize / full-screen). `appliedLayoutMode` starts nil so the
        // first updateUIView after makeUIView re-asserts the mode once and
        // re-seeks to the model's page (RESEARCH Pitfall 8: a display-mode
        // change can reset the visible page to 1).
        if context.coordinator.appliedLayoutMode != layoutMode {
            let oldMode = context.coordinator.appliedLayoutMode
            // A transition INVOLVES Single Page when either endpoint is
            // `.singlePage`. `usePageViewController(true)` is a sticky one-way
            // scroller swap with no documented off-toggle (Pitfall 1 / Open Q1),
            // so a plain in-place reconfigure into/out of Single Page can leave a
            // stale scroller. Guard on `oldMode != nil` so this fires ONLY on a
            // genuine LIVE switch on an already-realized PDFView — a fresh
            // `makeUIView` (oldMode == nil, e.g. after the parent `.id()` rebuild
            // landing in 31-03) takes the plain configure path and never
            // double-rebuilds.
            let involvesSinglePage = (oldMode == .singlePage) || (layoutMode == .singlePage)
            if involvesSinglePage, oldMode != nil {
                // HARDWARE-VERIFY (Pitfall 1 / Open Q1): live Single Page <-> other
                // switch. usePageViewController has no clean off-toggle, so we
                // rebuild the PDFView's internal scroller in place by re-applying
                // the layout and re-attaching the document, then re-seek from the
                // VM (single-page granularity — no spread map). The authoritative
                // fix is a fresh `makeUIView` driven by a parent `.id()` token,
                // which lands in 31-03; until then this is the in-place fallback.
                // Smoke-test item: toggle the view-mode setting while a book is
                // open and confirm no blank/duplicated page or dead swipes.
                configureMacLayout(uiView, mode: layoutMode)
                context.coordinator.appliedLayoutMode = layoutMode
                // Force the scroller to rebuild against the new display mode by
                // re-asserting the document, then re-seek the reading position.
                let doc = viewModel.document
                uiView.document = doc
                if let doc, viewModel.pageIndex < doc.pageCount,
                   let target = doc.page(at: viewModel.pageIndex) {
                    uiView.go(to: target)
                }
                // Re-install the KVO scroll observer against the rebuilt
                // scroller. Deferred to the next main-loop tick (mirroring
                // makeUIView) so PDFKit has built the new enclosed scroll view;
                // installScrollObserver is idempotent (invalidates the prior
                // token first) and degrades gracefully if no scroll view exists
                // yet (Pitfall 3). Inert for Single Page (Task 1 no-op switch),
                // active again once switched to Continuous/Two Page.
                let coordinator = context.coordinator
                DispatchQueue.main.async {
                    coordinator.installScrollObserver(on: uiView)
                }
            } else {
                // Continuous <-> Two Page (neither uses usePageViewController):
                // existing Phase 30 in-place reconfigure + re-seek, unchanged.
                configureMacLayout(uiView, mode: layoutMode)
                context.coordinator.appliedLayoutMode = layoutMode
                if let doc = viewModel.document {
                    let landingIndex: Int = (layoutMode == .twoUpSpread)
                        ? PDFReaderLayoutResolver.spreadLeftPage(
                            forPageIndex: viewModel.pageIndex,
                            displaysAsBook: uiView.displaysAsBook
                        )
                        : viewModel.pageIndex
                    if let target = doc.page(at: landingIndex) {
                        uiView.go(to: target)
                    }
                }
            }
        }
        #endif
    }

    private func themeBackground(_ theme: ReaderTheme) -> UIColor {
        switch theme {
        case .light: return UIColor(RishiColor.readerBackgroundLight)
        case .sepia: return UIColor(RishiColor.readerBackgroundSepia)
        case .dark:  return UIColor(RishiColor.readerBackgroundDark)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, PDFViewDelegate, UIGestureRecognizerDelegate {
        let viewModel: PDFReaderViewModel
        var onSelectionChange: (PDFSelection?) -> Void
        var onTap: (CGPoint) -> Void
        /// Phase 30 — last Mac layout mode applied to the live `PDFView`.
        /// Starts nil so the first `updateUIView` asserts the resolved mode
        /// once; thereafter only a live-resize mode change re-triggers the
        /// reconfigure + re-seek. Harmless on iOS (never read there).
        var appliedLayoutMode: PDFReaderLayoutMode?

        #if targetEnvironment(macCatalyst)
        // MARK: - Phase 30 plan 30-04 — Mac overscroll-to-turn / spread paging

        /// KVO token for the enclosed `UIScrollView`'s `contentOffset`. Stored
        /// so the observation lives as long as the Coordinator and is torn down
        /// in `deinit`. Pitfall 5: we OBSERVE the offset — we never assign the
        /// scroll view's `.delegate`, which would fight PDFKit's own paging.
        private var contentOffsetObservation: NSKeyValueObservation?
        /// Weak ref to the live PDFView so the offset callback can commit turns
        /// and drive the directional slide overlay without retaining the view.
        private weak var observedPDFView: PDFView?
        /// Accumulated overscroll past the relevant edge (Mode A). Reset on a
        /// committed turn and on a scroll-direction change (the latter handled
        /// inside `OverscrollTurnDecider.accumulate`).
        private var accumulatedOverscroll: CGFloat = 0
        /// Previous vertical offset, used to derive the instantaneous scroll
        /// direction and per-event delta for the accumulator.
        private var lastOffsetY: CGFloat = 0
        /// Previous horizontal offset, used to derive a discrete Mode-B swipe
        /// direction (one swipe = one spread, no accumulator).
        private var lastOffsetX: CGFloat = 0
        /// Last scroll direction (Mode A) so the accumulator resets on reversal.
        private var lastDirection: ScrollDirection = .none
        /// Debounce flag: while a turn is settling we ignore offset callbacks so
        /// one overscroll past threshold commits EXACTLY one page/spread turn.
        private var isTurnSettling: Bool = false
        #endif

        init(
            viewModel: PDFReaderViewModel,
            onSelectionChange: @escaping (PDFSelection?) -> Void,
            onTap: @escaping (CGPoint) -> Void
        ) {
            self.viewModel = viewModel
            self.onSelectionChange = onSelectionChange
            self.onTap = onTap
        }

        @objc func pdfViewPageChanged(_ note: Notification) {
            guard let pdfView = note.object as? PDFView,
                  let doc = pdfView.document,
                  let current = pdfView.currentPage else { return }
            let idx = doc.index(for: current)
            viewModel.didChangePage(toIndex: idx)
        }

        @objc func pdfViewSelectionChanged(_ note: Notification) {
            guard let pdfView = note.object as? PDFView else { return }
            // PDFView returns an empty (non-nil) selection on deselect — the
            // screen treats "empty" as "no selection" via PDFSelectionCoordinator,
            // so forwarding `currentSelection` as-is keeps the boundary simple.
            onSelectionChange(pdfView.currentSelection)
        }

        @objc func handleContainerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }
            onTap(recognizer.location(in: view))
        }

        /// Allow the tap recognizer to coexist with PDFKit's internal
        /// pan / tap / pinch recognizers. Without this, recognition
        /// arbitration delays or cancels the PDFView's pan, which
        /// reproduces the "can't swipe to next page" symptom users hit
        /// before Phase 21.
        public nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        #if targetEnvironment(macCatalyst)
        // MARK: - Phase 30 plan 30-04 — Mac scroll observation

        /// First `UIScrollView` descendant of the PDFView, or nil. Pitfall 3:
        /// the enclosed-scroll-view structure is NOT contractual, so this
        /// degrades gracefully — never force-unwraps. If no scroll view is
        /// found, no observer is installed and the gesture is simply absent
        /// (no crash, no behavior change).
        private func firstEnclosedScrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews {
                if let s = firstEnclosedScrollView(sub) { return s }
            }
            return nil
        }

        /// Installs the KVO observer on the PDFView's enclosed scroll view's
        /// `contentOffset` (Pitfall 5: observe, do NOT steal the delegate).
        /// Idempotent — a second call invalidates the prior token first so a
        /// re-realized scroll view never leaks an observer.
        func installScrollObserver(on pdfView: PDFView) {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            observedPDFView = pdfView
            guard let scroll = firstEnclosedScrollView(pdfView) else { return }
            lastOffsetY = scroll.contentOffset.y
            lastOffsetX = scroll.contentOffset.x
            // `[.new]` only — the closure reads `scroll` directly. Capture the
            // Coordinator weakly and hop to the MainActor (the Coordinator is
            // @MainActor) so the offset callback can touch the VM safely.
            contentOffsetObservation = scroll.observe(
                \.contentOffset,
                options: [.new]
            ) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    self?.handleContentOffsetChange(scrollView)
                }
            }
        }

        /// Routes an offset change to Mode A (overscroll accumulator + decider)
        /// or Mode B (one discrete swipe = one spread). Mode B is selected when
        /// the applied layout mode is `.twoUpSpread`; everything else is Mode A.
        private func handleContentOffsetChange(_ scroll: UIScrollView) {
            guard !isTurnSettling else { return }
            // Phase 31 — strict, exhaustive switch (no `default:`) so the
            // compiler forces a decision for every effective mode. Single Page
            // is INERT: PDFKit's UIPageViewController owns horizontal turns and
            // the directional-transition overlay (driven only from
            // handleOverscroll/handleSpreadSwipe) is therefore never triggered
            // there — correct, since PDFKit provides its own native horizontal
            // transition (Pitfall 2). Two Page + Continuous unchanged.
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

        /// Mode A — feed geometry into `OverscrollTurnDecider` and commit a turn
        /// once accumulated overscroll past the edge crosses the threshold.
        private func handleOverscroll(_ scroll: UIScrollView) {
            let offsetY = scroll.contentOffset.y
            let delta = offsetY - lastOffsetY
            let direction: ScrollDirection = delta > 0 ? .down : (delta < 0 ? .up : .none)
            // No vertical movement — nothing to accumulate or decide.
            guard direction != .none else { lastOffsetY = offsetY; return }

            accumulatedOverscroll = OverscrollTurnDecider.accumulate(
                current: accumulatedOverscroll,
                delta: delta,
                direction: direction,
                lastDirection: lastDirection
            )
            lastDirection = direction
            lastOffsetY = offsetY

            let decision = OverscrollTurnDecider.decide(
                offsetY: offsetY,
                contentHeight: scroll.contentSize.height,
                viewportHeight: scroll.bounds.height,
                accumulatedOverscroll: accumulatedOverscroll,
                direction: direction,
                isAtFirstPage: viewModel.pageIndex <= 0,
                isAtLastPage: viewModel.pageIndex >= viewModel.totalPages - 1
            )

            switch decision {
            case .turnNext:
                let next = min(viewModel.pageIndex + 1, max(viewModel.totalPages - 1, 0))
                viewModel.advancePage()
                viewModel.seek(toPage: next)
                resetAccumulator()
                runTransition(.fromTrailing)
            case .turnPrev:
                let prev = max(viewModel.pageIndex - 1, 0)
                viewModel.advancePage()
                viewModel.seek(toPage: prev)
                resetAccumulator()
                runTransition(.fromLeading)
            case .boundary:
                viewModel.hitBoundary()
                resetAccumulator()
            case .none:
                break
            }
        }

        /// Mode B — a single discrete horizontal scroll/swipe turns exactly one
        /// spread via `goToNextPage`/`goToPreviousPage` (no accumulator). The
        /// existing `.PDFViewPageChanged` loop keeps the VM in sync afterward.
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

        /// Resets the Mode-A accumulator and begins the settle debounce so the
        /// committed turn lands before any further offset callback is honored.
        private func resetAccumulator() {
            accumulatedOverscroll = 0
            lastDirection = .none
            beginTurnSettling()
        }

        /// Briefly ignores offset callbacks so the new page/spread settles and
        /// one overscroll/swipe commits exactly one turn (Pitfall 4 — no
        /// accidental multi-flips). Re-syncs `lastOffsetY/X` to the settled
        /// position on resume so the next delta is measured cleanly.
        private func beginTurnSettling() {
            isTurnSettling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if let scroll = self.observedPDFView.flatMap({ self.firstEnclosedScrollView($0) }) {
                    self.lastOffsetY = scroll.contentOffset.y
                    self.lastOffsetX = scroll.contentOffset.x
                }
                self.isTurnSettling = false
            }
        }

        /// Runs the directional snapshot-slide overlay (plan 30-04 Task 2) on
        /// the live PDFView, showing which side the incoming page enters from.
        /// No-op when the PDFView is gone or Reduce Motion is on (the overlay
        /// itself honors the accessibility setting).
        private func runTransition(_ edge: PDFPageTransitionEdge) {
            guard let pdfView = observedPDFView else { return }
            PDFPageTransitionOverlay.run(on: pdfView, edge: edge)
        }
        #endif

        deinit {
            #if targetEnvironment(macCatalyst)
            contentOffsetObservation?.invalidate()
            #endif
        }
    }
}
#endif
