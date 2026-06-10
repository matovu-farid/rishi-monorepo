#if canImport(UIKit)
import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiUIKit
import RishiLogging

/// SwiftUI wrapper for `EPUBNavigatorViewController`. iOS / Mac Catalyst only.
///
/// The view is driven by `EPUBReaderViewModel.publication`. When the
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
public struct EPUBReaderView: UIViewControllerRepresentable {

    public let viewModel: EPUBReaderViewModel
    /// Called whenever the user makes (or clears) a text selection in
    /// the navigator. The screen uses this to anchor the floating
    /// ``EPUBHighlightContextMenu``.
    public let onSelectionChange: (Selection?) -> Void
    /// Mutable reference holder so the screen can reach the
    /// coordinator after the SwiftUI representable has installed it.
    /// Mirrors the `pdfViewRef` pattern from Phase 5.
    public let coordinatorRef: EPUBCoordinatorRef

    public init(
        viewModel: EPUBReaderViewModel,
        onSelectionChange: @escaping (Selection?) -> Void = { _ in },
        coordinatorRef: EPUBCoordinatorRef = EPUBCoordinatorRef()
    ) {
        self.viewModel = viewModel
        self.onSelectionChange = onSelectionChange
        self.coordinatorRef = coordinatorRef
    }

    public func makeCoordinator() -> EPUBNavigatorCoordinator {
        let c = EPUBNavigatorCoordinator(viewModel: viewModel)
        c.onSelectionChange = onSelectionChange
        coordinatorRef.coordinator = c
        return c
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = backgroundUIColor(viewModel.theme)
        context.coordinator.onSelectionChange = onSelectionChange
        coordinatorRef.coordinator = context.coordinator
        attachNavigatorIfReady(into: container, coordinator: context.coordinator)
        return container
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.view.backgroundColor = backgroundUIColor(viewModel.theme)
        // Refresh closure to track SwiftUI re-renders (the screen owns
        // state that the closure captures — pendingSelection bindings, etc).
        context.coordinator.onSelectionChange = onSelectionChange
        coordinatorRef.coordinator = context.coordinator
        attachNavigatorIfReady(into: uiViewController, coordinator: context.coordinator)
    }

    private func attachNavigatorIfReady(into container: UIViewController, coordinator: EPUBNavigatorCoordinator) {
        do {
            try coordinator.makeNavigatorIfNeeded()
        } catch {
            Log.reader.error("Failed to construct EPUB navigator: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let navigator = coordinator.navigator else { return }
        // Avoid re-adding once installed.
        if navigator.parent === container { return }
        // Detach from any previous parent (defensive — coordinator could
        // be reused if SwiftUI rebuilds the container).
        navigator.willMove(toParent: nil)
        navigator.view.removeFromSuperview()
        navigator.removeFromParent()
        // Add as child VC + pin to container edges.
        container.addChild(navigator)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
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
        case .light: return UIColor(RishiColor.readerBackgroundLight)
        case .sepia: return UIColor(RishiColor.readerBackgroundSepia)
        case .dark:  return UIColor(RishiColor.readerBackgroundDark)
        }
    }
}

/// Mutable reference holder for the lazy ``EPUBNavigatorCoordinator``.
/// Lives on the SwiftUI screen so it can call
/// `coordinator?.applyHighlights(_:)` after `loadHighlights` and after
/// every create / delete. The screen instantiates this as `@State` so
/// SwiftUI keeps the same box across view rebuilds.
@MainActor
public final class EPUBCoordinatorRef {
    public weak var coordinator: EPUBNavigatorCoordinator?
    public init() {}
}
#endif
