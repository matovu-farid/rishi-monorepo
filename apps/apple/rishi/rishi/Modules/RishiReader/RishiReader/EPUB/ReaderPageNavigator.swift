#if canImport(UIKit)
import Foundation
import ReadiumNavigator

/// Drives forward / backward page turns on the Readium EPUB navigator.
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

    /// Advances one page forward: bumps the synthetic page-turn counter (haptic)
    /// then drives the navigator. No-op on the navigator side until Readium has
    /// installed it.
    public func goNext() {
        viewModel.advancePage()
        let navigator = coordinatorRef.coordinator?.navigator
        // KEEP: Readium EPUBNavigatorViewController requires @MainActor;
        // goForward is a navigator UI mutation.
        Task { @MainActor in
            _ = await navigator?.goForward(options: NavigatorGoOptions(animated: true))
        }
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
