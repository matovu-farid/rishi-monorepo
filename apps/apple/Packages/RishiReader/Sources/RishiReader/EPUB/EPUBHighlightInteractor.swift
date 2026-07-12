#if canImport(UIKit)
import SwiftUI
import RishiCore
import ReadiumShared
import ReadiumNavigator

/// Owns the selection -> highlight CRUD choreography for ``ReaderScreen``.
///
/// Extracted from the screen (Plan 34-03, SRP): the view used to inline four
/// `Task { @MainActor in ... }` blocks (`handleSelectionChange`,
/// `saveHighlight`, `startNoteFlow`, `commitNoteEdit`) that interleaved
/// view-model calls (`createHighlight` / `updateNote`), navigator-decoration
/// re-application (`applyHighlights` / `clearSelection`), and `@State` writes.
/// That orchestration is a view-model-layer concern; this type owns it while
/// the view retains its `@State` as the source of truth via SwiftUI `Binding`s.
///
/// Why bindings rather than returned state: the existing flow mutates several
/// pieces of UI state at distinct points inside async tasks (e.g. open the note
/// sheet only after the save succeeds). Threading bindings preserves that exact
/// timing and keeps behavior identical to the pre-refactor view.
///
/// `@MainActor` because every mutation here (VM calls, navigator decorations,
/// `@State` writes) runs on the main actor.
@MainActor
struct EPUBHighlightInteractor {

    private let viewModel: ReaderViewModel
    private let coordinatorRef: ReaderCoordinatorRef
    private let highlightStore: (any HighlightStore)?

    private let pendingSelection: Binding<SelectionContext?>
    private let noteText: Binding<String>
    private let activeSheet: Binding<ReaderSheet?>

    init(
        viewModel: ReaderViewModel,
        coordinatorRef: ReaderCoordinatorRef,
        highlightStore: (any HighlightStore)?,
        pendingSelection: Binding<SelectionContext?>,
        noteText: Binding<String>,
        activeSheet: Binding<ReaderSheet?>
    ) {
        self.viewModel = viewModel
        self.coordinatorRef = coordinatorRef
        self.highlightStore = highlightStore
        self.pendingSelection = pendingSelection
        self.noteText = noteText
        self.activeSheet = activeSheet
    }

    /// Stashes the locator for a fresh selection (showing the floating context
    /// menu) or clears the pending selection when the user deselects.
    ///
    /// Uses ``ReaderNavigatorCoordinator/highlightLocator(from:)`` so PDF
    /// selections get line rects attached before persistence.
    func handleSelectionChange(_ selection: Selection?) {
        guard let selection else {
            pendingSelection.wrappedValue = nil
            return
        }
        let locator = coordinatorRef.coordinator?.highlightLocator(from: selection)
            ?? EPUBSelectionCoordinator.makeLocator(from: selection)
        guard let locator else {
            pendingSelection.wrappedValue = nil
            return
        }
        pendingSelection.wrappedValue = SelectionContext(locator: locator, frame: selection.frame)
    }

    /// Creates a highlight in `color` from the pending selection, re-applies the
    /// navigator decorations, then clears the selection + menu.
    func saveHighlight(pending: SelectionContext, color: HighlightColor) {
        let store = highlightStore
        // KEEP: viewModel.createHighlight is @MainActor and coordinatorRef
        // .applyHighlights mutates the Readium navigator decorations API which
        // is @MainActor. UI state writes follow.
        Task { @MainActor in
            if let store {
                _ = await viewModel.createHighlight(
                    color: color,
                    locator: pending.locator,
                    note: nil,
                    store: store
                )
                coordinatorRef.coordinator?.applyHighlights(viewModel.loadedHighlights)
            }
            pendingSelection.wrappedValue = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    /// Saves a default yellow highlight, then opens the note editor bound to the
    /// saved row (mirrors the PDF flow).
    func startNoteFlow(for pending: SelectionContext) {
        let store = highlightStore
        // KEEP: viewModel.createHighlight is @MainActor, navigator decorations
        // are @MainActor, activeSheet is @State on the view.
        Task { @MainActor in
            guard let store else {
                pendingSelection.wrappedValue = nil
                return
            }
            // Save first with default yellow + empty note, then open the
            // editor bound to the saved row (mirrors PDF flow).
            if let saved = await viewModel.createHighlight(
                color: .yellow,
                locator: pending.locator,
                note: nil,
                store: store
            ) {
                coordinatorRef.coordinator?.applyHighlights(viewModel.loadedHighlights)
                noteText.wrappedValue = ""
                // Drive the single .sheet(item:) (Plan 18-08 / F-P2-01).
                activeSheet.wrappedValue = .highlightNote(saved)
            }
            pendingSelection.wrappedValue = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    /// Persists the edited note onto `highlight` and dismisses the editor sheet.
    func commitNoteEdit(on highlight: Highlight) {
        let text = noteText.wrappedValue
        let store = highlightStore
        // KEEP: viewModel.updateNote is @MainActor; activeSheet write needs main.
        Task { @MainActor in
            if let store {
                await viewModel.updateNote(
                    on: highlight,
                    note: text.isEmpty ? nil : text,
                    store: store
                )
            }
            activeSheet.wrappedValue = nil
        }
    }
}
#endif
