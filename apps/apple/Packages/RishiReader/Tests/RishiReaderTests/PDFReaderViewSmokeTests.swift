import Testing
import Foundation
import CoreGraphics
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

// Phase 30 Plan 30-03 note: the Mac-only `makeUIView`
// `#if targetEnvironment(macCatalyst)` branch (the real
// `.singlePageContinuous` / `.twoUp` render + the "no usePageViewController
// on Mac" guarantee) CANNOT be exercised on the iOS test host. It must be
// confirmed by the orchestrator's Mac Catalyst xcodebuild + a hardware pass
// (RESEARCH Open Questions 1-4: autoScales fit axis in .twoUp, displaysAsBook
// spread pairing, sizeRestrictions lifecycle, full-screen breakpoint firing).
// These smoke cases lock only the pure mode-request mapping + the new
// `layoutMode:` init signature. Swift Testing only; no XCTest.
//
// Phase 30 Plan 30-04 note: the genuinely-new Mac gesture glue — the KVO
// observer on the PDFView's enclosed UIScrollView contentOffset, the Mode-B
// `.twoUp` `goToNextPage`/`goToPreviousPage` spread turn, and the
// snapshot-slide `PDFPageTransitionOverlay` — is `targetEnvironment(macCatalyst)`
// only and is NOT reachable on the iOS test host. It is confirmed by the
// orchestrator's Mac Catalyst xcodebuild + a hardware pass (RESEARCH Open
// Questions 1-6: enclosed-scroll-view depth/feel, continuous-vs-windowed
// overscroll feel, `.twoUp` spread paging, Reduce-Motion slide gate). The
// Mode-A page-turn DECISION math is already pinned by OverscrollTurnDeciderTests;
// the cases below re-exercise that pure decider through representative gesture
// scenarios (accumulate-across-deltas then decide) so the observer's intended
// turn behavior is regression-locked at the decision boundary.
@Suite("PDFReaderView smoke", .serialized)
struct PDFReaderViewSmokeTests {

    @Test("VM-driven document property is reachable after load")
    @MainActor
    func vmDocumentReachable() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("smoke-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let book = Book(userId: UUID(), title: "Smoke", formatType: .pdf, fileURL: "x")
        let vm = PDFReaderViewModel(
            book: book, userId: UUID(),
            documentURL: url, positionStore: InMemoryPositionStore()
        )
        await vm.load()
        #expect(vm.document != nil)
        #expect(vm.totalPages == 3)

        #if canImport(UIKit)
        // PDFReaderView is a value type — instantiating it does not touch
        // UIKit (no makeUIView until the SwiftUI host adds it to a hierarchy),
        // so we can construct it in a unit-test environment to verify the
        // initializer + Bindable wiring compile against the VM contract.
        let view = PDFReaderView(viewModel: vm)
        _ = view  // suppress unused-warning
        #endif
    }

    // MARK: - Phase 30 — Mac layout-mode plumbing

    @Test("resolver requests two-up spread at a full-screen width")
    func resolverRequestsTwoUpWhenWide() {
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 1440, height: 900)
        )
        #expect(mode == .twoUpSpread)
    }

    @Test("resolver requests single fit-to-width at a narrow width")
    func resolverRequestsSingleWhenNarrow() {
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 700, height: 900)
        )
        #expect(mode == .singleFitWidth)
    }

    #if canImport(UIKit)
    @Test("PDFReaderView constructs in two-up spread mode")
    @MainActor
    func constructsTwoUp() {
        let vm = makeSmokeViewModel()
        let view = PDFReaderView(viewModel: vm, layoutMode: .twoUpSpread)
        #expect(view.layoutMode == .twoUpSpread)
    }

    @Test("PDFReaderView constructs in single fit-to-width mode")
    @MainActor
    func constructsSingleFitWidth() {
        let vm = makeSmokeViewModel()
        let view = PDFReaderView(viewModel: vm, layoutMode: .singleFitWidth)
        #expect(view.layoutMode == .singleFitWidth)
    }

    @Test("PDFReaderView default layoutMode is single fit-to-width")
    @MainActor
    func defaultLayoutModeIsSingle() {
        let vm = makeSmokeViewModel()
        let view = PDFReaderView(viewModel: vm)
        #expect(view.layoutMode == .singleFitWidth)
    }

    @MainActor
    private func makeSmokeViewModel() -> PDFReaderViewModel {
        let book = Book(userId: UUID(), title: "Smoke", formatType: .pdf, fileURL: "x")
        return PDFReaderViewModel(
            book: book,
            userId: book.userId,
            documentURL: URL.temporaryDirectory.appendingPathComponent("smoke-mode.pdf"),
            positionStore: InMemoryPositionStore(),
            documentLoader: { _ in nil }
        )
    }
    #endif

    // MARK: - Phase 30 plan 30-04 — Mode-A gesture scenarios through the pure decider

    /// At the very bottom + repeated DOWN deltas crossing the threshold commits a
    /// next-page turn — the path the Mac KVO observer drives in Mode A.
    @Test("at bottom + repeated down deltas crossing threshold -> .turnNext")
    func atBottomRepeatedDownCommitsTurnNext() {
        let threshold = OverscrollTurnDecider.defaultThreshold
        // Simulate the observer accumulating across several same-direction deltas
        // once the scroll view has bottomed out.
        var accumulated: CGFloat = 0
        var lastDirection: ScrollDirection = .none
        for _ in 0..<5 {
            accumulated = OverscrollTurnDecider.accumulate(
                current: accumulated,
                delta: 20,
                direction: .down,
                lastDirection: lastDirection
            )
            lastDirection = .down
        }
        #expect(accumulated >= threshold)

        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,   // 1400 + 600 == 2000 -> at bottom edge
            accumulatedOverscroll: accumulated,
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: false
        )
        #expect(decision == .turnNext)
    }

    /// Small jitter below the threshold (anti-accidental-flip) stays `.none` even
    /// at the bottom edge — no page turn on an incidental nudge.
    @Test("small jitter below threshold at bottom -> .none")
    func smallJitterBelowThresholdIsNone() {
        var accumulated: CGFloat = 0
        accumulated = OverscrollTurnDecider.accumulate(
            current: accumulated,
            delta: 4,
            direction: .down,
            lastDirection: .none
        )
        #expect(accumulated < OverscrollTurnDecider.defaultThreshold)

        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: accumulated,
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: false
        )
        #expect(decision == .none)
    }

    /// On the LAST page, bottoming out + overscrolling past threshold reports a
    /// document boundary (warn) instead of flipping past the end.
    @Test("last page at bottom + over threshold -> .boundary")
    func lastPageAtBottomReportsBoundary() {
        var accumulated: CGFloat = 0
        var lastDirection: ScrollDirection = .none
        for _ in 0..<4 {
            accumulated = OverscrollTurnDecider.accumulate(
                current: accumulated,
                delta: 25,
                direction: .down,
                lastDirection: lastDirection
            )
            lastDirection = .down
        }
        let decision = OverscrollTurnDecider.decide(
            offsetY: 1400,
            contentHeight: 2000,
            viewportHeight: 600,
            accumulatedOverscroll: accumulated,
            direction: .down,
            isAtFirstPage: false,
            isAtLastPage: true
        )
        #expect(decision == .boundary)
    }
}
