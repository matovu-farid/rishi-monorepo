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
        DispatchQueue.main.async { ready(pdfView) }
        return pdfView
    }

    #if targetEnvironment(macCatalyst)
    /// Mac-only per-mode `PDFView` configuration. NEVER calls
    /// `usePageViewController` (RESEARCH Pitfall 1/7: it ignores
    /// `displayMode` and disables fit). Mode A = single fit-to-width with
    /// vertical scrolling; Mode B = two-up height-fit spread.
    private func configureMacLayout(_ pdfView: PDFView, mode: PDFReaderLayoutMode) {
        switch mode {
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
    }
}
#endif
