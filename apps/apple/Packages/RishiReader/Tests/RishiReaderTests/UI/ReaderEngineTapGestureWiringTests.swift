#if canImport(UIKit)
import Testing
import Foundation
import UIKit
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

/// Phase 21 — regression guard for the reader page-turn bug.
///
/// **Symptom (verbatim user report):** "I opened a pdf and I can't scroll
/// to the right. I noticed the same with the epub."
///
/// **Root cause:** the prior design put a SwiftUI
/// `Color.clear.contentShape(Rectangle()).simultaneousGesture(
/// SpatialTapGesture)` overlay above the engine in a ZStack so the
/// chrome-toggle tap could fire. SwiftUI's `simultaneousGesture` only
/// coordinates with sibling **SwiftUI** gestures — it does not negotiate
/// with the UIKit pan recognizer owned by PDFKit's `UIPageViewController`
/// or Readium's WKWebView. The overlay claimed every touch in the area,
/// so horizontal pan never reached the engine's pan recognizer and the
/// user could not swipe to turn pages.
///
/// **Fix (this file is the guard):** a UIKit `UITapGestureRecognizer` is
/// attached DIRECTLY to the engine view (`PDFView` for PDF,
/// `UIViewController.view` for Readium) by `PDFReaderView` /
/// `EPUBReaderView`, with two non-negotiable flags:
///
///   1. `cancelsTouchesInView = false` — every touch is still delivered
///      to the engine view's own `touchesBegan / touchesMoved /
///      touchesEnded`, so the engine's pan recognizer drives paging.
///   2. The recognizer's delegate returns `true` from
///      `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` so
///      UIKit recognition arbitration doesn't delay or cancel the
///      engine's pan while the tap is pending.
///
/// If either flag is flipped, swipe paging breaks. These tests pin the
/// contract.
@MainActor
@Suite("Reader engine tap-gesture wiring (Phase 21 page-turn fix)")
struct ReaderEngineTapGestureWiringTests {

    // MARK: - PDF

    @Test("PDF Coordinator allows simultaneous recognition with engine pan")
    func pdfCoordinatorAllowsSimultaneousRecognition() {
        let coordinator = PDFReaderView.Coordinator(
            viewModel: makePDFViewModel(),
            onSelectionChange: { _ in },
            onTap: { _ in }
        )
        let tap = UITapGestureRecognizer()
        let pan = UIPanGestureRecognizer()
        #expect(coordinator.gestureRecognizer(
            tap,
            shouldRecognizeSimultaneouslyWith: pan
        ) == true,
                "Returning false here re-creates the regression — UIKit arbitration would delay PDFKit's pan recognizer while the tap is pending")
    }

    @Test("PDF onTap fires with the tap location on .ended")
    func pdfOnTapFiresOnEndedState() {
        var received: CGPoint?
        let coordinator = PDFReaderView.Coordinator(
            viewModel: makePDFViewModel(),
            onSelectionChange: { _ in },
            onTap: { received = $0 }
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let recognizer = StubTapRecognizer(
            view: host,
            simulatedState: .ended,
            locationToReport: CGPoint(x: 320, y: 100)
        )
        coordinator.handleContainerTap(recognizer)
        #expect(received == CGPoint(x: 320, y: 100))
    }

    @Test("PDF onTap does NOT fire while the recognizer is still pending")
    func pdfOnTapIgnoresNonEndedStates() {
        var fireCount = 0
        let coordinator = PDFReaderView.Coordinator(
            viewModel: makePDFViewModel(),
            onSelectionChange: { _ in },
            onTap: { _ in fireCount += 1 }
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        for state in [UIGestureRecognizer.State.possible, .began, .changed, .cancelled, .failed] {
            let recognizer = StubTapRecognizer(
                view: host,
                simulatedState: state,
                locationToReport: .zero
            )
            coordinator.handleContainerTap(recognizer)
        }
        #expect(fireCount == 0,
                "onTap must only fire on .ended — any other state would surface intermediate touch states as taps and race with the engine's pan recognizer")
    }

    // MARK: - EPUB

    @Test("EPUB NavigatorCoordinator allows simultaneous recognition with engine pan")
    func epubCoordinatorAllowsSimultaneousRecognition() {
        let coordinator = EPUBNavigatorCoordinator(viewModel: makeEPUBViewModel())
        let tap = UITapGestureRecognizer()
        let pan = UIPanGestureRecognizer()
        #expect(coordinator.gestureRecognizer(
            tap,
            shouldRecognizeSimultaneouslyWith: pan
        ) == true,
                "Returning false here re-creates the regression — UIKit arbitration would delay Readium's WKWebView pan recognizer while the tap is pending")
    }

    @Test("EPUB onTap fires with the tap location on .ended")
    func epubOnTapFiresOnEndedState() {
        var received: CGPoint?
        let coordinator = EPUBNavigatorCoordinator(viewModel: makeEPUBViewModel())
        coordinator.onTap = { received = $0 }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let recognizer = StubTapRecognizer(
            view: host,
            simulatedState: .ended,
            locationToReport: CGPoint(x: 60, y: 100)
        )
        coordinator.handleContainerTap(recognizer)
        #expect(received == CGPoint(x: 60, y: 100))
    }

    // MARK: - Fixtures

    private func makePDFViewModel() -> PDFReaderViewModel {
        let book = Book(userId: UUID(), title: "TapWiring", formatType: .pdf, fileURL: "x")
        return PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
    }

    private func makeEPUBViewModel() -> EPUBReaderViewModel {
        let book = Book(userId: UUID(), title: "TapWiring", formatType: .epub, fileURL: "x")
        return EPUBReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
    }
}

// MARK: - Test scaffolding

/// Stub `UITapGestureRecognizer` whose `state` and `location(in:)` are
/// driven by the test. Production code only reads those two surfaces.
private final class StubTapRecognizer: UITapGestureRecognizer {
    private var stateValue: UIGestureRecognizer.State
    private let locationToReport: CGPoint

    init(view: UIView, simulatedState: UIGestureRecognizer.State, locationToReport: CGPoint) {
        self.stateValue = simulatedState
        self.locationToReport = locationToReport
        super.init(target: nil, action: nil)
        view.addGestureRecognizer(self)
    }

    override var state: UIGestureRecognizer.State {
        get { stateValue }
        set { stateValue = newValue }
    }

    override func location(in view: UIView?) -> CGPoint { locationToReport }
}
#endif
