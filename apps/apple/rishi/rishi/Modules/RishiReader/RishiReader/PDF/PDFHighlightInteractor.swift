#if canImport(UIKit)
import Foundation
import PDFKit


/// Phase 34 Plan 34-02 (SRP P0) — owns the highlight CRUD orchestration that
/// previously lived as `handleSelectionChange` / `saveHighlight` /
/// `startNoteFlow` / `commitNoteEdit` inside the `PDFReaderScreen` `View`.
///
/// Each of those methods buried `Task { @MainActor in ... }` + `await
/// viewModel.createHighlight/updateNote` choreography in the view. This type
/// pulls that orchestration into the view-model layer, returning the next
/// `@State` values (pending highlight / active sheet) instead of mutating the
/// view's `@State` inline. The view keeps `@State` ownership and just applies
/// the returned outcomes — behavior is identical, but the async VM dance no
/// longer lives in the `View`.
///
/// `@MainActor` because every method reads/writes the `@MainActor`
/// ``PDFReaderViewModel`` (and its `@Observable` highlight cache).
@MainActor
struct PDFHighlightInteractor {
    private let viewModel: PDFReaderViewModel
    private let highlightStore: (any HighlightStore)?

    init(viewModel: PDFReaderViewModel, highlightStore: (any HighlightStore)?) {
        self.viewModel = viewModel
        self.highlightStore = highlightStore
    }

    /// Resolves a PDFKit selection to a ``PendingHighlight`` (or `nil` when the
    /// selection cannot be located). Pure with respect to the store; matches
    /// the original `handleSelectionChange` exactly.
    func pendingHighlight(for selection: PDFSelection?) -> PendingHighlight? {
        guard let selection,
              let document = viewModel.document,
              let locator = PDFSelectionCoordinator.makeLocator(from: selection, in: document)
        else {
            return nil
        }
        return PendingHighlight(locator: locator, text: locator.text)
    }

    /// Persists a highlight with the picked `color`. Mirrors the original
    /// `saveHighlight`: no-ops the store call when no store is wired, and the
    /// caller clears `pendingHighlight` afterwards.
    func save(pending: PendingHighlight, color: HighlightColor, note: String?) async {
        guard let store = highlightStore else { return }
        _ = await viewModel.createHighlight(
            color: color,
            locator: pending.locator,
            note: note,
            store: store
        )
    }

    /// Starts the add-note flow: saves a default-yellow highlight, then returns
    /// the saved row so the caller can open the editor sheet bound to it.
    /// Returns `nil` when there is no store or the save failed — matching the
    /// original `startNoteFlow` control flow.
    func startNoteFlow(for pending: PendingHighlight) async -> Highlight? {
        guard let store = highlightStore else { return nil }
        // Save first with default yellow + empty note, then open the editor
        // bound to the saved row.
        return await viewModel.createHighlight(
            color: .yellow,
            locator: pending.locator,
            note: nil,
            store: store
        )
    }

    /// Commits a note edit onto an existing highlight. No-ops the store call
    /// when no store is wired; matches the original `commitNoteEdit`.
    func commitNote(on highlight: Highlight, text: String) async {
        guard let store = highlightStore else { return }
        await viewModel.updateNote(
            on: highlight,
            note: text.isEmpty ? nil : text,
            store: store
        )
    }
}
#endif
