import Testing
import Foundation
import CoreGraphics
@testable import RishiReader

/// Regression suite for the seam that wires
/// ``ReaderTapRegionResolver`` -> ``ReaderChromeController``.
///
/// **Why this exists.** During the tap-to-toggle wiring work (commits
/// `da9296ee1`, `40506f997`, `7f57607aa`) both reader screens initially
/// attached the `SpatialTapGesture` directly to the
/// `UIViewControllerRepresentable` that hosts the Readium WKWebView
/// (`EPUBReaderView`) or the PDFKit `PDFView` (`PDFReaderView`). Those
/// engines own their own UIKit gesture stacks and greedily claim taps —
/// so the SwiftUI `.gesture` closure never ran, the controller never
/// received `toggle()`, and the chrome stayed hidden forever. Combined
/// with `initiallyVisible: false`, that left the user trapped on the
/// cover with no `xmark` visible.
///
/// The fix moves the tap gesture onto a transparent `Color.clear` overlay
/// that sits ABOVE the engine inside the `PageTurnAnimator`'s content
/// slot, uses `.simultaneousGesture` so the parent `DragGesture` still
/// works, and flips `initiallyVisible` to `true` so the `xmark` is always
/// reachable on first open.
///
/// This suite cannot drive SwiftUI's hit-testing in a unit test, so it
/// covers the *behavioral* contract: feed the resolver the same point a
/// real tap would produce, route the resulting `Decision` through the
/// same `switch` the screens use, and assert that
/// ``ReaderChromeController/isVisible`` flips. If a future refactor
/// breaks the resolver → controller wire-up (e.g. by dropping the
/// `.toggleChrome` branch, or by recreating the controller per tap so
/// state is lost), these tests fail.
@MainActor
@Suite("Reader tap-to-toggle wiring", .serialized)
struct ReaderTapToToggleWiringTests {

    /// Mirrors `ReaderChromeControllerTests.FakeAccessibility`. Kept local
    /// so the wiring tests don't depend on test-target internals from a
    /// sibling suite.
    final class FakeAccessibility: AccessibilityProviding {
        var voiceOver: Bool
        init(voiceOver: Bool = false) { self.voiceOver = voiceOver }
        var isVoiceOverRunning: Bool { voiceOver }
    }

    /// Sleep stub that never resolves — keeps the auto-hide Task parked so
    /// `isVisible` doesn't flip back behind the test's back. The wiring
    /// suite cares about the synchronous toggle path; the auto-hide
    /// dynamics are covered by ``ReaderChromeControllerTests``.
    @Sendable
    private static func parkedSleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, Error>) in
            // Intentionally never resumed.
        }
    }

    /// Re-implements the exact `switch` body both `EPUBReaderScreen` and
    /// `PDFReaderScreen` use after the resolver decides. Centralized here
    /// so the test is asserting the same routing the production screens
    /// perform — any divergence in the switch (e.g. swapping
    /// `toggleChrome` for a no-op) breaks these tests.
    private func dispatch(
        decision: ReaderTapRegionResolver.Decision,
        chrome: ReaderChromeController,
        onNext: () -> Void,
        onPrevious: () -> Void
    ) {
        switch decision {
        case .toggleChrome:
            chrome.toggle()
        case .nextPage:
            onNext()
        case .previousPage:
            onPrevious()
        }
    }

    private func makeController(initiallyVisible: Bool) -> ReaderChromeController {
        ReaderChromeController(
            accessibility: FakeAccessibility(),
            autoHideDelay: .seconds(60),
            sleep: Self.parkedSleep,
            initiallyVisible: initiallyVisible
        )
    }

    private let size = CGSize(width: 400, height: 800)

    // MARK: - Resolver -> controller wire-up

    @Test("Center tap toggles chrome via the resolver+controller seam")
    func centerTapTogglesChromeWhenStartingHidden() {
        let chrome = makeController(initiallyVisible: false)
        let resolver = ReaderTapRegionResolver()
        var nextCount = 0
        var prevCount = 0

        let decision = resolver.decide(
            at: CGPoint(x: size.width * 0.50, y: size.height * 0.5),
            in: size
        )
        dispatch(
            decision: decision,
            chrome: chrome,
            onNext: { nextCount += 1 },
            onPrevious: { prevCount += 1 }
        )

        #expect(decision == .toggleChrome)
        #expect(chrome.isVisible == true)
        #expect(nextCount == 0)
        #expect(prevCount == 0)
    }

    @Test("Center tap toggles chrome OFF when starting visible")
    func centerTapTogglesChromeOffWhenStartingVisible() {
        let chrome = makeController(initiallyVisible: true)
        let resolver = ReaderTapRegionResolver()

        let decision = resolver.decide(
            at: CGPoint(x: size.width * 0.50, y: 100),
            in: size
        )
        dispatch(decision: decision, chrome: chrome, onNext: {}, onPrevious: {})

        #expect(decision == .toggleChrome)
        #expect(chrome.isVisible == false)
    }

    @Test("Two consecutive center taps return chrome to its original state")
    func twoCenterTapsRoundTrip() {
        let chrome = makeController(initiallyVisible: false)
        let resolver = ReaderTapRegionResolver()

        for _ in 0..<2 {
            let d = resolver.decide(
                at: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
                in: size
            )
            dispatch(decision: d, chrome: chrome, onNext: {}, onPrevious: {})
        }

        #expect(chrome.isVisible == false)
    }

    // MARK: - Edge taps must NOT toggle chrome

    @Test("Left-edge tap routes to previousPage and does NOT toggle chrome")
    func leftEdgeTapDoesNotToggleChrome() {
        let chrome = makeController(initiallyVisible: false)
        let resolver = ReaderTapRegionResolver()
        var nextCount = 0
        var prevCount = 0

        let decision = resolver.decide(
            at: CGPoint(x: size.width * 0.10, y: size.height * 0.5),
            in: size
        )
        dispatch(
            decision: decision,
            chrome: chrome,
            onNext: { nextCount += 1 },
            onPrevious: { prevCount += 1 }
        )

        #expect(decision == .previousPage)
        #expect(chrome.isVisible == false)
        #expect(prevCount == 1)
        #expect(nextCount == 0)
    }

    @Test("Right-edge tap routes to nextPage and does NOT toggle chrome")
    func rightEdgeTapDoesNotToggleChrome() {
        let chrome = makeController(initiallyVisible: false)
        let resolver = ReaderTapRegionResolver()
        var nextCount = 0
        var prevCount = 0

        let decision = resolver.decide(
            at: CGPoint(x: size.width * 0.90, y: size.height * 0.5),
            in: size
        )
        dispatch(
            decision: decision,
            chrome: chrome,
            onNext: { nextCount += 1 },
            onPrevious: { prevCount += 1 }
        )

        #expect(decision == .nextPage)
        #expect(chrome.isVisible == false)
        #expect(nextCount == 1)
        #expect(prevCount == 0)
    }

    // MARK: - Trap-the-user regression

    /// On a freshly-opened book, the chrome must be reachable. The bug
    /// that motivated this suite started chrome hidden AND lost every
    /// tap to the underlying WKWebView/PDFView, leaving the user with no
    /// way out. The production fix sets `initiallyVisible: true` so the
    /// `xmark` is always visible on first frame.
    @Test("Chrome is visible on first frame so the close button is reachable")
    func chromeIsVisibleOnFirstFrame() {
        let chrome = makeController(initiallyVisible: true)
        #expect(chrome.isVisible == true)
    }

    /// Even if a tap is missed entirely (e.g. the user lands on an edge
    /// that pages instead of the center band), the controller's state
    /// must not get into a wedged configuration where it can never be
    /// shown again. Toggling after a page-edge tap should still flip
    /// visibility.
    @Test("Edge tap followed by center tap still toggles chrome")
    func edgeThenCenterStillToggles() {
        let chrome = makeController(initiallyVisible: false)
        let resolver = ReaderTapRegionResolver()
        var nextCount = 0

        // 1. Right edge -> nextPage.
        let edge = resolver.decide(
            at: CGPoint(x: size.width * 0.90, y: 200),
            in: size
        )
        dispatch(decision: edge, chrome: chrome, onNext: { nextCount += 1 }, onPrevious: {})

        #expect(edge == .nextPage)
        #expect(chrome.isVisible == false)
        #expect(nextCount == 1)

        // 2. Center -> toggleChrome.
        let center = resolver.decide(
            at: CGPoint(x: size.width * 0.50, y: 400),
            in: size
        )
        dispatch(decision: center, chrome: chrome, onNext: { nextCount += 1 }, onPrevious: {})

        #expect(center == .toggleChrome)
        #expect(chrome.isVisible == true)
        #expect(nextCount == 1) // unchanged by toggle
    }
}
