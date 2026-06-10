#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
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
///
/// **Sendability:** `@MainActor` matches Readium's `EPUBNavigatorDelegate`
/// protocol declaration, so delegate methods don't need `nonisolated`.
@MainActor
public final class EPUBNavigatorCoordinator: NSObject {

    public let viewModel: EPUBReaderViewModel
    public private(set) var navigator: EPUBNavigatorViewController?

    public init(viewModel: EPUBReaderViewModel) {
        self.viewModel = viewModel
        super.init()
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
        viewModel.didChangeLocation(locator)
    }

    public func navigator(_ navigator: any Navigator, presentExternalURL url: URL) {
        // Phase-6 v1: log + ignore. Open-in-Safari behavior is a later concern.
        Log.reader.debug("EPUB external URL tap: \(url.absoluteString, privacy: .public)")
    }

    public func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        Log.reader.error("EPUB navigator error: \(error.localizedDescription, privacy: .public)")
    }
}
#endif
