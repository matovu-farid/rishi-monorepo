#if canImport(UIKit)
import Foundation
import ReadiumNavigator
import ReadiumShared

/// Drives forward / backward page turns on a Readium reader navigator.
///
/// Extracted from ``ReaderScreen`` (Plan 34-03, SRP): the tap handler used
/// to reach through `coordinatorRef.coordinator?.navigator` and `await`
/// `goForward` / `goBackward` inline — engine-call orchestration living inside a
/// SwiftUI `View`. That knowledge of Readium's navigator API now lives here, so
/// the view only expresses intent (`goNext()` / `goPrev()`).
///
/// Each turn also bumps the view-model's synthetic page counter
/// (`advancePage()`), which drives the SwiftUI `.sensoryFeedback` page-turn
/// haptic — Readium owns the real position; the counter is synthetic because
/// EPUB has no integer pages.
///
/// `@MainActor` because Readium's `EPUBNavigatorViewController` requires the
/// main actor and `advancePage()` mutates `@Observable` VM state.
@MainActor
public struct ReaderPageNavigator {

    private let viewModel: ReaderViewModel
    private let coordinatorRef: ReaderCoordinatorRef

    public init(viewModel: ReaderViewModel, coordinatorRef: ReaderCoordinatorRef) {
        self.viewModel = viewModel
        self.coordinatorRef = coordinatorRef
    }

    /// Advances one page forward and reports whether Readium moved. During an
    /// explicit PDF narration turn, the correlated intent is registered before
    /// Readium starts its asynchronous navigation callback sequence.
    @discardableResult
    public func goNext(explicitForwardID: UUID? = nil) async -> Bool {
        viewModel.advancePage()
        guard let coordinator = coordinatorRef.coordinator,
              let navigator = coordinator.navigator else { return false }

        if let pdfNavigator = navigator as? PDFNavigatorViewController,
           let explicitForwardID {
            let originPage = pdfNavigator.currentLocation?.locations.page
                ?? viewModel.visibleNavigatorLocator?.locations.page
            guard let originPage,
                  coordinator.registerExplicitPageForward(id: explicitForwardID, originPage: originPage) else {
                return false
            }
            _ = await pdfNavigator.goForward(options: NavigatorGoOptions(animated: true))
            let finalLocation = pdfNavigator.currentLocation
            let didMove = finalLocation?.locations.page.map { $0 != originPage } ?? false
            _ = coordinator.completeExplicitPageForward(
                id: explicitForwardID,
                didMove: didMove,
                finalLocation: finalLocation
            )
            return didMove
        }

        return await navigator.goForward(options: NavigatorGoOptions(animated: true))
    }

    /// Turns one page backward. Same counter-then-navigator sequence as
    /// ``goNext()``.
    public func goPrev() {
        viewModel.advancePage()
        let navigator = coordinatorRef.coordinator?.navigator
        // KEEP: Readium navigator UI mutation; @MainActor.
        Task { @MainActor in
            _ = await navigator?.goBackward(options: NavigatorGoOptions(animated: true))
        }
    }
}
#endif
