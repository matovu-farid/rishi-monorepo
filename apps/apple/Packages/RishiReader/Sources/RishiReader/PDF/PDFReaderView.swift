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
/// `PDFView` subclass that keeps the Mac Continuous (Mode A) page fit to the
/// viewport WIDTH across live window resize / full-screen toggles.
///
/// PDFKit has no built-in fit-WIDTH: `autoScales`/`scaleFactorForSizeToFit`
/// fit the WHOLE page (so it never overflows and there is nothing to scroll,
/// which would defeat the Phase 30 overscroll-to-turn). Mode A instead pins
/// `scaleFactor = availableWidth / pageWidth` so the page fills the width and
/// overflows vertically. `configureMacLayout` only runs in `makeUIView`
/// (bounds may still be 0) and on mode changes — not on every resize — so the
/// scale must be re-derived from the live bounds here in `layoutSubviews`.
///
/// The recompute fires ONLY when `fitsWidthToSinglePage` is true, set ONLY in
/// the `.singleFitWidth` branch. On iOS and in the `.singlePage` /
/// `.twoUpSpread` branches the flag stays false, so this subclass behaves
/// exactly like a plain `PDFView` (no scale override) and iOS/EPUB are
/// byte-identical.
final class FitWidthPDFView: PDFView {
    /// When true, `layoutSubviews` re-pins `scaleFactor` to the fit-width value
    /// derived from the current bounds + `currentPage`. Default false so every
    /// other path (iOS, Single Page, Two Page) is untouched.
    var fitsWidthToSinglePage: Bool = false

    #if targetEnvironment(macCatalyst)
    /// The fit-width scale is derived from `currentPage`, which only exists once
    /// the (asynchronously loaded) document is assigned. If the realized-bounds
    /// `layoutSubviews` pass already fired while the document was still nil,
    /// nothing re-pins the scale when the document finally arrives, leaving the
    /// page stuck at the fallback 1x (tiny, centered). Re-pin on every document
    /// assignment and request a fresh layout pass so the scale corrects whether
    /// the page or the bounds settle last.
    override var document: PDFDocument? {
        didSet {
            applyFitWidthIfNeeded()
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFitWidthIfNeeded()
    }

    /// Recomputes and applies the fit-width scale from the live bounds and the
    /// current page width. No-op unless `fitsWidthToSinglePage` is true and the
    /// bounds + page width are usable. Idempotent — skips reassigning when the
    /// scale already matches so PDFKit's own layout pass does not thrash.
    func applyFitWidthIfNeeded() {
        guard fitsWidthToSinglePage else { return }
        guard let page = currentPage else { return }
        let pageWidth = page.bounds(for: displayBox).width
        let availableWidth = bounds.width
        // Bail when either input is unrealized (bounds still 0, or a degenerate
        // page) so we never pin the fallback 1x scale and flash a tiny page; the
        // next layout/document event re-invokes this once the inputs are ready.
        guard pageWidth > 0, availableWidth > 0 else { return }
        let target = PDFReaderLayoutResolver.fitWidthScaleFactor(
            pageWidth: pageWidth,
            availableWidth: availableWidth
        )
        guard target > 0 else { return }
        // Keep the user able to pinch-zoom but default to fit-width: the min
        // floor is the fit-to-page (whole page visible) scale, the max is 4x.
        let fitPage = scaleFactorForSizeToFit
        minScaleFactor = min(fitPage, target)
        maxScaleFactor = 4.0
        if abs(scaleFactor - target) > 0.001 {
            scaleFactor = target
        }
    }
    #endif
}

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
        // FitWidthPDFView is a plain PDFView unless its `fitsWidthToSinglePage`
        // flag is set (only the Mac `.singleFitWidth` branch sets it), so iOS
        // behavior is byte-identical to using a bare PDFView.
        let pdfView = FitWidthPDFView()
        #if targetEnvironment(macCatalyst)
        // Phase 30/31 — Mac has THREE layout modes, all selected by
        // `configureMacLayout` from the resolved `layoutMode`:
        //   - Single Page (`.singlePage`): one page, horizontal page-turns;
        //     this is the ONLY Mac mode that calls usePageViewController.
        //   - Continuous (`.singleFitWidth`): ONE page fit to WIDTH (page
        //     overflows vertically), scroll within the page, overscroll past
        //     the edge turns to the next/prev page. Uses `displayMode =
        //     .singlePage` + a computed fit-width `scaleFactor` (NOT PDFKit
        //     continuous mode, which would flow all pages together and break
        //     the per-page overscroll-to-turn).
        //   - Two Page (`.twoUpSpread`): two-up height-fit spread.
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
    /// Mac-only per-mode `PDFView` configuration. The Continuous (Mode A) and
    /// two-up (Mode B) cases NEVER call `usePageViewController` (RESEARCH
    /// Pitfall 1/7: it ignores `displayMode` and disables fit). Phase 31's
    /// Single Page case DOES call it (it restores the pre-Phase-30 horizontal
    /// page-turn config) — because that toggle is sticky, transitions
    /// into/out of Single Page rebuild the `PDFView` rather than reconfigure
    /// in place (see updateUIView). Mode A = ONE page fit to WIDTH with vertical
    /// scroll-within-page + overscroll-to-turn (`displayMode = .singlePage`,
    /// `autoScales = false`, computed fit-width `scaleFactor`; NOT PDFKit
    /// `.singlePageContinuous`, which flows all pages and breaks per-page
    /// overscroll); Mode B = two-up height-fit spread; Single Page = one page,
    /// horizontal page-turn.
    private func configureMacLayout(_ pdfView: PDFView, mode: PDFReaderLayoutMode) {
        // The live-resize fit-width flag lives on the FitWidthPDFView subclass
        // (makeUIView always creates one). Set it ONLY for Continuous; clear it
        // for every other mode so they keep PDFKit's native scaling untouched.
        let fitWidthView = pdfView as? FitWidthPDFView
        switch mode {
        case .singlePage:
            // Phase 31 — restore the pre-Phase-30 Mac config (it IS the iOS
            // `#else` block): one page at a time, horizontal page-turns, whole
            // page fit. usePageViewController(true) MUST be first; it is a
            // sticky one-way scroller swap (Pitfall 1) — switching into/out of
            // this mode on a live PDFView is handled by the rebuild path in
            // updateUIView, NOT an in-place reconfigure.
            fitWidthView?.fitsWidthToSinglePage = false
            pdfView.usePageViewController(true, withViewOptions: nil)
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.autoScales = true
            pdfView.minScaleFactor = 0.5
            pdfView.maxScaleFactor = 4.0
        case .singleFitWidth:
            // Continuous = ONE page (NOT PDFKit continuous, which would flow
            // all pages together and break per-page overscroll-to-turn), fit to
            // WIDTH so the page overflows vertically and the user scrolls within
            // it; overscroll past the edge turns the page (Phase 30 observer).
            // PDFKit has no fit-WIDTH, so autoScales is OFF and `scaleFactor` is
            // pinned to availableWidth/pageWidth — re-derived on every resize by
            // FitWidthPDFView.layoutSubviews while `fitsWidthToSinglePage` is on.
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .vertical
            pdfView.autoScales = false
            let pageWidth = pdfView.currentPage?.bounds(for: pdfView.displayBox).width ?? 0
            let target = PDFReaderLayoutResolver.fitWidthScaleFactor(
                pageWidth: pageWidth,
                availableWidth: pdfView.bounds.width
            )
            let fitPage = pdfView.scaleFactorForSizeToFit
            pdfView.minScaleFactor = min(fitPage > 0 ? fitPage : target, target)
            pdfView.maxScaleFactor = 4.0
            pdfView.scaleFactor = target
            // Turn on live-resize fit-width LAST so the first layout pass after
            // this reconfigure re-pins the scale from the realized bounds (in
            // makeUIView the bounds are often still 0 at this point).
            fitWidthView?.fitsWidthToSinglePage = true
        case .twoUpSpread:
            fitWidthView?.fitsWidthToSinglePage = false
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
        ///
        /// On Mac the value is mirrored into `pager` so the overscroll machine
        /// selects Mode A vs Mode B; the `didSet` keeps the two in sync.
        #if targetEnvironment(macCatalyst)
        var appliedLayoutMode: PDFReaderLayoutMode? {
            didSet { pager?.appliedLayoutMode = appliedLayoutMode }
        }
        #else
        var appliedLayoutMode: PDFReaderLayoutMode?
        #endif

        #if targetEnvironment(macCatalyst)
        /// Phase 34 plan 34-04 — the Mac overscroll-to-turn / spread paging state
        /// machine, extracted out of the Coordinator so this object stays a thin
        /// PDFKit delegate. Created lazily on the first `installScrollObserver`.
        /// iOS never reaches this branch.
        private var pager: PDFOverscrollPageTurnDetector?
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
        // MARK: - Phase 30 plan 30-04 — Mac scroll observation (delegated)

        /// Installs (or re-installs) the Mac overscroll-to-turn / spread paging
        /// observer on the PDFView's enclosed scroll view. The Coordinator owns
        /// the lifecycle here but DELEGATES the entire KVO/accumulator/debounce
        /// state machine to ``PDFOverscrollPageTurnDetector`` (plan 34-04). The
        /// detector is created lazily on first install and reused thereafter, so
        /// a re-realized scroll view (live Single Page <-> other rebuild) is
        /// re-observed idempotently (the detector invalidates the prior token).
        func installScrollObserver(on pdfView: PDFView) {
            let detector = pager ?? PDFOverscrollPageTurnDetector(target: viewModel)
            pager = detector
            detector.appliedLayoutMode = appliedLayoutMode
            detector.installScrollObserver(on: pdfView)
        }
        #endif
    }
}
#endif
