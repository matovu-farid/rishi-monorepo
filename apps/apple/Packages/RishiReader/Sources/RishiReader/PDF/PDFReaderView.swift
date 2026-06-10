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
public struct PDFReaderView: UIViewRepresentable {

    public let viewModel: PDFReaderViewModel

    public init(viewModel: PDFReaderViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

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
        return pdfView
    }

    public func updateUIView(_ uiView: PDFView, context: Context) {
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
    public final class Coordinator: NSObject, PDFViewDelegate {
        let viewModel: PDFReaderViewModel
        init(viewModel: PDFReaderViewModel) { self.viewModel = viewModel }

        @objc func pdfViewPageChanged(_ note: Notification) {
            guard let pdfView = note.object as? PDFView,
                  let doc = pdfView.document,
                  let current = pdfView.currentPage else { return }
            let idx = doc.index(for: current)
            viewModel.didChangePage(toIndex: idx)
        }
    }
}
#endif
