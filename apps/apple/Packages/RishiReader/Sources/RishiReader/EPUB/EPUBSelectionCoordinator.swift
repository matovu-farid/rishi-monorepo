import Foundation
import ReadiumShared
#if canImport(UIKit)
import ReadiumNavigator
#endif

/// Converts a Readium `Selection` into the persistent shape we store —
/// an ``EPUBHighlightLocator`` (opaque Readium `Locator.jsonString()`
/// payload + cached snippet).
///
/// The coordinator is the EPUB analogue of ``PDFSelectionCoordinator``:
/// pure-Swift, stateless, callable from any actor. The screen reads
/// `navigator.currentSelection` when the selection delegate fires
/// (Readium 3.9 is pull-based — see ``ReaderNavigatorCoordinator``).
///
/// **Discrimination contract:** a selection whose `text.highlight` is
/// missing, empty, or whitespace-only is rejected (returns `nil`). The
/// reader UI uses the `nil` return as the "no menu" signal so the
/// floating context menu never appears for empty selections.
public enum EPUBSelectionCoordinator {

    /// Trim-and-reject path operating on the underlying `Locator`.
    /// Exposed separately from ``makeLocator(from:)`` so tests can drive
    /// the codec without constructing a Readium `Selection` (which is
    /// `UIKit`-gated through `ReadiumNavigator`).
    public static func makeLocator(fromLocator locator: Locator) -> EPUBHighlightLocator? {
        let snippet = locator.text.highlight ?? ""
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return EPUBHighlightLocator(locator: locator)
    }

    #if canImport(UIKit)
    /// Entry point used by the screen when the user finishes selecting
    /// text in the navigator. Returns `nil` for empty / whitespace-only
    /// selections so the caller can suppress the context menu.
    public static func makeLocator(from selection: Selection) -> EPUBHighlightLocator? {
        makeLocator(fromLocator: selection.locator)
    }
    #endif
}
