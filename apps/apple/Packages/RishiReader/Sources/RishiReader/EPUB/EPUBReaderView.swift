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
public struct EPUBReaderView: UIViewControllerRepresentable {

    public let viewModel: EPUBReaderViewModel

    public init(viewModel: EPUBReaderViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> EPUBNavigatorCoordinator {
        EPUBNavigatorCoordinator(viewModel: viewModel)
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = backgroundUIColor(viewModel.theme)
        attachNavigatorIfReady(into: container, coordinator: context.coordinator)
        return container
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.view.backgroundColor = backgroundUIColor(viewModel.theme)
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
#endif
