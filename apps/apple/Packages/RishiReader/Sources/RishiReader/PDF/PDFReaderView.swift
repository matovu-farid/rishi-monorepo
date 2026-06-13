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
        onSelectionChange: @escaping (PDFSelection?) -> Void = { _ in },
        onPDFViewReady: @escaping (PDFView) -> Void = { _ in },
        onTap: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
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
        // MUST be first: switches PDFView's internal scroller to a UIPageViewController.
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 4.0
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
