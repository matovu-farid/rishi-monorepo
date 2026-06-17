#if canImport(UIKit)
import Foundation

/// Sequences the read-aloud follow-highlight choreography on the navigator
/// coordinator.
///
/// Extracted from ``EPUBReaderScreen`` (Plan 34-03, SRP): the screen's
/// `applyReadAloudHighlight()` used to flip `coordinator.isFollowingReadAloud`,
/// call `highlightReadAloudParagraph`, and kick off
/// `navigateToReadAloudParagraph` inline. That call-sequencing is a service
/// concern (it already delegates entirely to ``EPUBNavigatorCoordinator``);
/// moving it out of the view leaves the view expressing only "the active
/// paragraph changed".
///
/// `@MainActor` because the coordinator is `@MainActor`.
@MainActor
public struct EPUBReadAloudPresenter {

    private let coordinatorRef: EPUBCoordinatorRef

    public init(coordinatorRef: EPUBCoordinatorRef) {
        self.coordinatorRef = coordinatorRef
    }

    /// Pushes `paragraph` into the navigator as the active `"rishi-tts"`
    /// decoration and follows it (turning the page when it has scrolled onto a
    /// later page), or clears the decoration when `paragraph` is `nil`.
    /// No-ops until the navigator coordinator is installed.
    ///
    /// A non-nil paragraph means a read-aloud session is following the text;
    /// while it is, the coordinator treats navigator location changes as
    /// auto-follow (not user page-turns) so the follow does not stop the audio
    /// it is chasing. Cleared when the session ends (paragraph -> nil).
    public func apply(paragraph: String?) {
        guard let coordinator = coordinatorRef.coordinator else { return }
        coordinator.isFollowingReadAloud = paragraph != nil
        if let paragraph {
            coordinator.highlightReadAloudParagraph(paragraph)
            // Follow the spoken paragraph so the page turns when it has moved
            // onto a later page (auto-advance and the prev/next/repeat buttons
            // both flow through here). go(to:) is a no-op when the paragraph is
            // already on the current page.
            Task { await coordinator.navigateToReadAloudParagraph(paragraph) }
        } else {
            coordinator.clearReadAloudHighlight()
        }
    }
}
#endif
