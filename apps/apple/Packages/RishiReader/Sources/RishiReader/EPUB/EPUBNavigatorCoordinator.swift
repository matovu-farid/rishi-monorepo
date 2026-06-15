#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiCore
import RishiLogging

/// Constructs and owns the `EPUBNavigatorViewController` for a single
/// open EPUB. The coordinator is the bridge between Readium's
/// delegate callbacks and our `EPUBReaderViewModel`.
///
/// Lifecycle:
///   1. `EPUBReaderView.makeUIViewController` creates the coordinator,
///      which lazily constructs the navigator from the VM's
///      `publication` + `latestLocator`.
///   2. The coordinator hands the navigator back to UIKit.
///   3. On every locator change, `navigator(_:locationDidChange:)`
///      forwards to `viewModel.didChangeLocation(_:)`.
///   4. When the user finishes a selection, Readium asks the delegate
///      whether to show its default menu
///      (`SelectableNavigatorDelegate.navigator(_:shouldShowMenuForSelection:)`).
///      We return `false` and forward the selection to the screen via
///      `onSelectionChange`, which presents our floating
///      ``EPUBHighlightContextMenu`` instead.
///
/// **Sendability:** `@MainActor` matches Readium's `EPUBNavigatorDelegate`
/// protocol declaration, so delegate methods don't need `nonisolated`.
@MainActor
public final class EPUBNavigatorCoordinator: NSObject {

    public let viewModel: EPUBReaderViewModel
    public private(set) var navigator: EPUBNavigatorViewController?

    /// True while a read-aloud session is actively following the spoken
    /// paragraph. Set by ``EPUBReaderScreen`` from the active-passage binding.
    /// The view-follow (``navigateToReadAloudParagraph(_:)``) owns navigation
    /// for the whole session, so EVERY locator change while this is true is
    /// auto-follow — not a user page-turn — and must NOT fire `onUserNavigation`
    /// (which would stop the audio the view is following).
    ///
    /// Why session-scoped, not per-navigation: the read-aloud target locator is
    /// text-anchored with NO progression, and within one resource a programmatic
    /// page turn and a user swipe carry the same href, so the two are
    /// indistinguishable from a single `locationDidChange`. An animated
    /// `go(to:)` also delivers its `locationDidChange` ~300ms AFTER it returns,
    /// so any flag reset tied to the call races the callback (the original bug:
    /// the late callback was read as a user page-turn and fired
    /// `onUserNavigation -> stopReadAloud`, halting read-aloud at every page
    /// boundary). Gating on "is a session following" sidesteps both problems.
    /// The cost is that a manual page-turn during read-aloud no longer stops it
    /// (use the Stop control) — the auto-follow would immediately yank the view
    /// back to the spoken paragraph anyway. Set and read on the MainActor, so
    /// no synchronization is needed.
    public var isFollowingReadAloud = false

    /// Forwarded to the screen so it can present the highlight context
    /// menu. The closure is also called with `nil` when the user clears
    /// the selection — readers should hide the menu in that case.
    ///
    /// Readium 3.9 does NOT expose a push-style `selectionDidChange`
    /// callback. We fire `onSelectionChange` from
    /// `navigator(_:shouldShowMenuForSelection:)` (the only delegate
    /// method that gets a fresh `Selection` payload). Returning `false`
    /// suppresses Readium's default `UIMenuController` so the floating
    /// menu owns the surface.
    public var onSelectionChange: (Selection?) -> Void = { _ in }

    /// Phase 21 — fired by the container-level `UITapGestureRecognizer`
    /// installed in ``EPUBReaderView``. The screen uses it to drive the
    /// tap-region resolver (left edge -> previous, center -> chrome
    /// toggle, right edge -> next). `point` is in the container view's
    /// coordinate space.
    public var onTap: (CGPoint) -> Void = { _ in }

    public init(viewModel: EPUBReaderViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    /// Selector wired by
    /// ``EPUBReaderView/installContainerTapRecognizer(on:coordinator:)``.
    /// Forwards the tap location to ``onTap`` only when the recognizer
    /// reports `.ended`.
    @objc public func handleContainerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let view = recognizer.view else { return }
        onTap(recognizer.location(in: view))
    }

    /// Re-applies the supplied highlights as Readium decorations in the
    /// `"rishi-highlights"` group. Safe to call before the navigator is
    /// built — no-ops in that case (the screen re-applies after load).
    public func applyHighlights(_ highlights: [Highlight]) {
        guard let nav = navigator else { return }
        EPUBDecorationApplier.apply(highlights: highlights, to: nav)
    }

    /// Marks `paragraph` as the active read-aloud passage by replacing the
    /// single decoration in the `"rishi-tts"` group. The locator is anchored
    /// to the current resource (`latestLocator`); no-ops until the navigator
    /// and a locator both exist.
    public func highlightReadAloudParagraph(_ paragraph: String) {
        guard let nav = navigator,
              let locator = viewModel.latestLocator else { return }
        let decoration = EPUBReadAloudDecorationBuilder.decoration(
            forParagraph: paragraph,
            href: locator.href,
            mediaType: locator.mediaType
        )
        nav.apply(decorations: [decoration], in: EPUBReadAloudDecorationBuilder.groupName)
    }

    /// Clears the active read-aloud passage decoration (called when TTS
    /// stops). No-ops before the navigator is built.
    public func clearReadAloudHighlight() {
        navigator?.apply(decorations: [], in: EPUBReadAloudDecorationBuilder.groupName)
    }

    /// Follows the active read-aloud paragraph: navigates the viewport to the
    /// paragraph's locator so the page turns when the spoken paragraph has
    /// scrolled onto a later page. Uses the SAME text-anchored locator as the
    /// highlight (`EPUBReadAloudDecorationBuilder.locator`), so a locator on the
    /// current page is a no-op and one on the next page turns it. No-ops until
    /// the navigator and a base locator both exist.
    @discardableResult
    public func navigateToReadAloudParagraph(_ paragraph: String) async -> Bool {
        guard let nav = navigator,
              let base = viewModel.latestLocator else { return false }
        let locator = EPUBReadAloudDecorationBuilder.locator(
            forParagraph: paragraph,
            href: base.href,
            mediaType: base.mediaType
        )
        // The locator change this produces is suppressed via `isFollowingReadAloud`
        // (a read-aloud session owns navigation for its whole duration), so no
        // per-call marker is needed here.
        return await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
    }

    /// Translates our reader settings into Readium's `EPUBPreferences`
    /// and submits them to the navigator. Safe to call before the
    /// navigator is built — no-ops in that case; the screen re-applies
    /// after `load()` completes.
    public func applyPreferences(
        typography: ReaderTypography,
        theme: ReaderTheme,
        spread: EPUBSpreadMode
    ) {
        guard let nav = navigator else { return }
        EPUBPreferencesBridge.apply(
            typography: typography,
            theme: theme,
            spread: spread,
            to: nav
        )
    }

    /// Navigates to the destination encoded by the supplied TOC `Link`.
    /// Used by ``EPUBTOCView``'s onSelect callback. No-ops if the
    /// navigator hasn't been built yet.
    @discardableResult
    public func go(to link: ReadiumShared.Link) async -> Bool {
        guard let nav = navigator else { return false }
        return await nav.go(to: link, options: NavigatorGoOptions(animated: true))
    }

    /// Imperatively clears the live selection (used after a highlight
    /// is saved so the menu doesn't stay anchored to old text).
    public func clearSelection() {
        navigator?.clearSelection()
    }

    /// Builds the navigator if not already built. Safe to call multiple
    /// times — second call is a no-op. Returns silently when the
    /// publication is not yet loaded; the caller (View.updateUIViewController)
    /// will retry on the next SwiftUI tick once `viewModel.publication`
    /// becomes non-nil.
    public func makeNavigatorIfNeeded() throws {
        if navigator != nil { return }
        guard let publication = viewModel.publication else {
            Log.reader.debug("EPUBNavigatorCoordinator: publication not yet loaded; deferring navigator build")
            return
        }
        let nav = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: viewModel.latestLocator
        )
        nav.delegate = self
        self.navigator = nav
    }
}

extension EPUBNavigatorCoordinator: EPUBNavigatorDelegate {

    public func navigator(_ navigator: any Navigator, locationDidChange locator: Locator) {
        handleLocationChange(locator)
    }

    /// Forwards a navigator location change to the view model, tagging it as
    /// programmatic auto-follow while a read-aloud session is active so the VM
    /// does not treat it as a user page-turn. Separated from the delegate method
    /// (which requires a live `Navigator`) so it is unit-testable without one.
    public func handleLocationChange(_ locator: Locator) {
        viewModel.didChangeLocation(locator, isProgrammatic: isFollowingReadAloud)
    }

    public func navigator(_ navigator: any Navigator, presentExternalURL url: URL) {
        // Phase-6 v1: log + ignore. Open-in-Safari behavior is a later concern.
        Log.reader.debug("EPUB external URL tap: \(url.absoluteString, privacy: .public)")
    }

    public func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        Log.reader.error("EPUB navigator error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - SelectableNavigatorDelegate

    /// Suppress Readium's default selection menu and forward the
    /// selection to the screen so it can present
    /// ``EPUBHighlightContextMenu``. `EPUBNavigatorDelegate` already
    /// inherits `SelectableNavigatorDelegate`, so no extra conformance
    /// is needed.
    public func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        onSelectionChange(selection)
        return false
    }
}

extension EPUBNavigatorCoordinator: UIGestureRecognizerDelegate {

    /// Allow the container-level `UITapGestureRecognizer` to coexist
    /// with Readium's internal pan / tap / long-press recognizers.
    /// Without this, UIKit's recognition arbitration may delay or cancel
    /// the engine's pan recognizer while the tap is pending, which
    /// reproduces the "can't swipe to next page" symptom users hit
    /// before Phase 21.
    public nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
