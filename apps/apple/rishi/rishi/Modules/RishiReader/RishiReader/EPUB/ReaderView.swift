#if canImport(UIKit)
import SwiftUI
import UIKit
import os.signpost
import ReadiumShared
import ReadiumNavigator

private let readerNavigatorAttachmentSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)



/// SwiftUI wrapper for Readium's EPUB/PDF visual navigators. iOS / Mac Catalyst only.
///
/// The view is driven by `ReaderViewModel.publication`. When the
/// publication is `nil` (mid-load), we render an empty container view
/// painted with the theme background — SwiftUI re-invokes
/// `updateUIViewController` on the next observation tick so the navigator
/// gets installed as soon as `load()` completes.
///
/// **Sendability:** the wrapper is a `View` value type; the coordinator
/// holds the navigator instance and is the long-lived owner.
///
/// **Phase 4 theme handling:** we apply the per-theme reader background
/// directly to the container `UIViewController.view` so the active palette
/// shows around the navigator's content (partial EPUB-04 coverage —
/// in-content CSS theme application is layered in Plan 06-06).
///
/// **Phase 5 selection wiring** (06-05):
///   - `onSelectionChange` is forwarded to `coordinator.onSelectionChange`
///     in `makeUIViewController` AND refreshed on every
///     `updateUIViewController` (so SwiftUI re-renders pick up new closures).
///   - `coordinatorRef.coordinator` is published back to the screen so it
///     can call `applyHighlights(_:)` after `loadHighlights` and after each
///     create/delete.
public struct ReaderView: UIViewControllerRepresentable {

    public let viewModel: ReaderViewModel
    public let pageTheme: ReaderTheme
    public let pdfViewMode: PDFViewModeSetting
    public let pdfViewModeBinding: Binding<PDFViewModeSetting>?
    /// Called whenever the user makes (or clears) a text selection in
    /// the navigator. The screen uses this to anchor the floating
    /// ``EPUBHighlightContextMenu``.
    public let onSelectionChange: (Selection?) -> Void
    /// Called after Readium reports a committed page/location change.
    public let onPageLocationChange: () -> Void
    public let onPageForward: () -> Void
    public let onPageBackward: () -> Void
    public let onEscape: () -> Bool
    /// Called once after Readium reports the initial visible location.
    public let onFirstContentReady: @MainActor () async -> Void
    /// Phase 21 — single-tap callback driven by a UIKit
    /// `UITapGestureRecognizer` attached directly to the engine's
    /// container view with `cancelsTouchesInView = false`. This replaces
    /// the prior SwiftUI `Color.clear.contentShape(Rectangle())
    /// .simultaneousGesture(SpatialTapGesture(...))` overlay above the
    /// navigator: on iOS 26 the overlay's hit-test region intercepted
    /// horizontal pan touches too, the SwiftUI gesture system's
    /// pending-recognition phase blocked Readium's WKWebView pan
    /// recognizer, and the user could not swipe to the next page. The
    /// UIKit recognizer only fires on a discrete tap; with
    /// `cancelsTouchesInView = false` the pan stream still reaches the
    /// engine and horizontal swipes turn pages again.
    ///
    /// `point` is in the container view's coordinate space.
    public let onTap: (CGPoint) -> Void
    /// Mutable reference holder so the screen can reach the
    /// coordinator after the SwiftUI representable has installed it.
    /// Mirrors the `pdfViewRef` pattern from Phase 5.
    public let coordinatorRef: ReaderCoordinatorRef

    public init(
        viewModel: ReaderViewModel,
        pageTheme: ReaderTheme,
        pdfViewMode: PDFViewModeSetting = .continuous,
        pdfViewModeBinding: Binding<PDFViewModeSetting>? = nil,
        onSelectionChange: @escaping (Selection?) -> Void = { _ in },
        onPageLocationChange: @escaping () -> Void = {},
        onPageForward: @escaping () -> Void = {},
        onPageBackward: @escaping () -> Void = {},
        onEscape: @escaping () -> Bool = { false },
        onFirstContentReady: @escaping @MainActor () async -> Void = {},
        onTap: @escaping (CGPoint) -> Void = { _ in },
        coordinatorRef: ReaderCoordinatorRef = ReaderCoordinatorRef()
    ) {
        self.viewModel = viewModel
        self.pageTheme = pageTheme
        self.pdfViewMode = pdfViewMode
        self.pdfViewModeBinding = pdfViewModeBinding
        self.onSelectionChange = onSelectionChange
        self.onPageLocationChange = onPageLocationChange
        self.onPageForward = onPageForward
        self.onPageBackward = onPageBackward
        self.onEscape = onEscape
        self.onFirstContentReady = onFirstContentReady
        self.onTap = onTap
        self.coordinatorRef = coordinatorRef
    }

    public func makeCoordinator() -> ReaderNavigatorCoordinator {
        let c = ReaderNavigatorCoordinator(viewModel: viewModel)
        c.onSelectionChange = onSelectionChange
        c.onPageLocationChange = onPageLocationChange
        c.onPageForward = onPageForward
        c.onPageBackward = onPageBackward
        c.onEscape = onEscape
        c.onFirstContentReady = onFirstContentReady
        c.onTap = onTap
        coordinatorRef.coordinator = c
        return c
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = backgroundUIColor(pageTheme)
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onPageLocationChange = onPageLocationChange
        context.coordinator.onPageForward = onPageForward
        context.coordinator.onPageBackward = onPageBackward
        context.coordinator.onEscape = onEscape
        context.coordinator.onFirstContentReady = onFirstContentReady
        context.coordinator.onTap = onTap
        context.coordinator.pdfViewMode = pdfViewModeBinding?.wrappedValue ?? pdfViewMode
        coordinatorRef.coordinator = context.coordinator
        installContainerTapRecognizer(on: container.view, coordinator: context.coordinator)
        attachNavigatorIfReady(into: container, coordinator: context.coordinator)
        return container
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.view.backgroundColor = backgroundUIColor(pageTheme)
        // Refresh closure to track SwiftUI re-renders (the screen owns
        // state that the closure captures — pendingSelection bindings, etc).
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onPageLocationChange = onPageLocationChange
        context.coordinator.onPageForward = onPageForward
        context.coordinator.onPageBackward = onPageBackward
        context.coordinator.onEscape = onEscape
        context.coordinator.onFirstContentReady = onFirstContentReady
        context.coordinator.onTap = onTap
        context.coordinator.pdfViewMode = pdfViewModeBinding?.wrappedValue ?? pdfViewMode
        coordinatorRef.coordinator = context.coordinator
        attachNavigatorIfReady(into: uiViewController, coordinator: context.coordinator)
    }

    public static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: ReaderNavigatorCoordinator
    ) {
        coordinator.cancelPendingFirstContentCallback()
    }

    /// Installs a single-tap `UITapGestureRecognizer` on the container
    /// view. `cancelsTouchesInView = false` is the critical flag: every
    /// touch is still delivered to the Readium WKWebView beneath so
    /// horizontal pan drives page turns. The recognizer's delegate
    /// returns `true` from
    /// `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` so the
    /// engine's pan recognizer is not blocked by recognition arbitration.
    private func installContainerTapRecognizer(
        on view: UIView,
        coordinator: ReaderNavigatorCoordinator
    ) {
        let tap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(ReaderNavigatorCoordinator.handleContainerTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
    }

    private func attachNavigatorIfReady(into container: UIViewController, coordinator: ReaderNavigatorCoordinator) {
        do {
            try coordinator.makeNavigatorIfNeeded()
        } catch {
            Log.reader.error("Failed to construct Readium navigator: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let navigator = coordinator.navigator else { return }
        // Avoid re-adding once installed.
        if navigator.parent === container { return }
        let attachmentState = readerNavigatorAttachmentSignposter.beginInterval("reader.navigator.attach")
        defer {
            readerNavigatorAttachmentSignposter.endInterval("reader.navigator.attach", attachmentState)
        }
        // Detach from any previous parent (defensive — coordinator could
        // be reused if SwiftUI rebuilds the container).
        navigator.willMove(toParent: nil)
        navigator.view.removeFromSuperview()
        navigator.removeFromParent()
        // Add as child VC + pin to container edges.
        container.addChild(navigator)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
        // UI tests (RISHI_UITEST) assert on the SwiftUI toolbar + Read Aloud
        // controls overlaid on the reader. Readium's WKWebView publishes its
        // page text as Link/StaticText accessibility nodes (in the web-content
        // process) whose automation type XCUITest cannot resolve, which aborts
        // the whole-app accessibility snapshot and makes those sibling controls
        // unqueryable. A SwiftUI `.accessibilityHidden` does NOT reach the
        // WKWebView; hiding the navigator's UIKit view subtree does. Touch
        // handling is unaffected, so tap-to-turn-page still works. DEBUG +
        // env-gated, so it never affects a release build or real VoiceOver.
        #if DEBUG
        if ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1" {
            navigator.view.accessibilityElementsHidden = true
        }
        #endif
        container.view.addSubview(navigator.view)
        NSLayoutConstraint.activate([
            navigator.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            navigator.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            navigator.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            navigator.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        ])
        navigator.didMove(toParent: container)
    }

    private func backgroundUIColor(_ theme: ReaderTheme) -> UIColor {
        switch theme {
        case .matchDevice:
            return UIColor(readerSurfaceColor(for: theme))
        case .light:
            return UIColor(readerSurfaceColor(for: theme))
        case .sepia: return UIColor(RishiColor.readerBackgroundSepia)
        case .dark:  return UIColor(RishiColor.readerBackgroundDark)
        }
    }

    private func readerSurfaceColor(for theme: ReaderTheme) -> SwiftUI.Color {
        switch theme {
        case .matchDevice, .light:
            return viewModel.book.formatType == .epub
                ? .white
                : RishiColor.readerBackgroundLight
        case .sepia:
            return RishiColor.readerBackgroundSepia
        case .dark:
            return RishiColor.readerBackgroundDark
        }
    }
}

/// Mutable reference holder for the lazy ``ReaderNavigatorCoordinator``.
/// Lives on the SwiftUI screen so it can call
/// `coordinator?.applyHighlights(_:)` after `loadHighlights` and after
/// every create / delete. The screen instantiates this as `@State` so
/// SwiftUI keeps the same box across view rebuilds.
@MainActor
public final class ReaderCoordinatorRef {
    public weak var coordinator: ReaderNavigatorCoordinator?
    public init() {}
}
#endif
