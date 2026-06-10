import SwiftUI
import RishiCore
import RishiUIKit
#if canImport(UIKit)
import UIKit
import ReadiumShared
import ReadiumNavigator
#endif

/// Top-level SwiftUI screen for reading an EPUB.
///
/// Composes:
///   - ``EPUBReaderView`` (UIKit-gated Readium navigator wrapper)
///   - ``EPUBReaderToolbar`` (close + title + TOC/typography/theme buttons)
///   - ``EPUBProgressIndicator`` (floating bottom percent chip)
///   - ``EPUBHighlightContextMenu`` (4-color palette + Add Note, 06-05)
///   - ``HighlightNoteEditor`` sheet (06-05; reused from Phase 5)
///
/// Behavior parallels ``PDFReaderScreen``:
///   - ZStack(reader, chrome, context menu) with tap-to-toggle chrome.
///   - On `.task`, calls `await viewModel.load()`, hydrates theme +
///     typography from the (optional) ``ReaderSettingsStore``, and
///     calls `loadHighlights` + re-applies the decorations on the
///     coordinator.
///   - On selection change: stash the locator as `pendingSelection`,
///     show the floating context menu. Color tap → create highlight,
///     re-apply decorations, dismiss menu. Add Note → create a yellow
///     highlight then open the note editor bound to it.
///   - On dismiss, calls `await viewModel.flush()` BEFORE `dismiss()` so
///     the final locator persists.
///
/// TOC / theme / typography sheet plumbing lands in Plan 06-06. The
/// closures are intentionally empty placeholders here; the toolbar already
/// hides them behind `isPublicationLoaded` so users can't fire blank UI.
///
/// On macOS dev hosts (non-Catalyst, no UIKit), the reader area renders a
/// compile-only stub label — ship targets always hit the UIKit branch.
@MainActor
public struct EPUBReaderScreen: View {

    private let viewModel: EPUBReaderViewModel
    /// Optional injection: when `nil`, the screen runs against an ephemeral
    /// settings store (no persistence). Production wiring in
    /// `AppDependencies` passes a `UserDefaultsReaderSettingsStore`.
    private let readerSettingsStore: (any ReaderSettingsStore)?
    /// Optional injection: when `nil`, the highlight UI is mounted but
    /// never persists. Production wiring in `AppDependencies` passes
    /// `GRDBHighlightStore`.
    private let highlightStore: (any HighlightStore)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible: Bool = true

    #if canImport(UIKit)
    @State private var pendingSelection: SelectionContext?
    @State private var editingHighlight: Highlight?
    @State private var noteText: String = ""
    /// Lazy reference to the live navigator coordinator; populated by
    /// ``EPUBReaderView`` once Readium installs the navigator. We use
    /// it to re-apply decorations after loadHighlights / createHighlight
    /// / deleteHighlight.
    @State private var coordinatorRef = EPUBCoordinatorRef()
    #endif

    public init(
        viewModel: EPUBReaderViewModel,
        readerSettingsStore: (any ReaderSettingsStore)? = nil,
        highlightStore: (any HighlightStore)? = nil
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
    }

    public var body: some View {
        ZStack {
            background

            #if canImport(UIKit)
            EPUBReaderView(
                viewModel: viewModel,
                onSelectionChange: { selection in
                    handleSelectionChange(selection)
                },
                coordinatorRef: coordinatorRef
            )
            .ignoresSafeArea()
            .onTapGesture {
                chromeVisible.toggle()
            }
            .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

            if let pending = pendingSelection {
                EPUBHighlightContextMenu(
                    selectionFrame: pending.frame,
                    onColor: { color in
                        saveHighlight(pending: pending, color: color)
                    },
                    onAddNote: {
                        startNoteFlow(for: pending)
                    },
                    onDismiss: {
                        pendingSelection = nil
                        coordinatorRef.coordinator?.clearSelection()
                    }
                )
                .transition(.opacity)
            }
            #else
            // macOS dev-host stub for compile-only — ship hits the UIKit
            // branch above on iOS + Mac Catalyst.
            Text("EPUB reader requires iOS or Mac Catalyst")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            #endif

            if chromeVisible {
                VStack {
                    EPUBReaderToolbar(
                        title: viewModel.title.isEmpty ? viewModel.book.title : viewModel.title,
                        isPublicationLoaded: viewModel.publication != nil,
                        onClose: {
                            Task {
                                await viewModel.flush()
                                dismiss()
                            }
                        },
                        onShowTOC: { /* wired in 06-06 */ },
                        onShowTheme: { /* wired in 06-06 */ },
                        onShowTypography: { /* wired in 06-06 */ }
                    )
                    Spacer()
                    EPUBProgressIndicator(
                        totalProgression: viewModel.latestLocator?.locations.totalProgression
                    )
                    .padding(.bottom, RishiSpacing.m)
                }
                .transition(.opacity)
            }
        }
        .task {
            await viewModel.load()
            if let settings = readerSettingsStore {
                viewModel.theme = await settings.theme(for: viewModel.book.id)
                viewModel.typography = await settings.typography(for: viewModel.book.id)
            }
            #if canImport(UIKit)
            if let store = highlightStore {
                await viewModel.loadHighlights(from: store)
                coordinatorRef.coordinator?.applyHighlights(viewModel.loadedHighlights)
            }
            #endif
        }
        #if canImport(UIKit)
        .sheet(item: $editingHighlight) { hl in
            HighlightNoteEditor(
                note: $noteText,
                snippet: hl.text,
                onSave: { commitNoteEdit(on: hl) },
                onCancel: { editingHighlight = nil }
            )
        }
        #endif
        #if !os(macOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    private var background: some View {
        switch viewModel.theme {
        case .light: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .sepia: RishiColor.readerBackgroundSepia.ignoresSafeArea()
        case .dark:  RishiColor.readerBackgroundDark.ignoresSafeArea()
        }
    }

    // MARK: - Selection / highlight flow (UIKit-only)

    #if canImport(UIKit)
    private func handleSelectionChange(_ selection: Selection?) {
        guard let selection,
              let locator = EPUBSelectionCoordinator.makeLocator(from: selection) else {
            pendingSelection = nil
            return
        }
        pendingSelection = SelectionContext(locator: locator, frame: selection.frame)
    }

    private func saveHighlight(pending: SelectionContext, color: HighlightColor) {
        let store = highlightStore
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
            pendingSelection = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    private func startNoteFlow(for pending: SelectionContext) {
        let store = highlightStore
        Task { @MainActor in
            guard let store else {
                pendingSelection = nil
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
                noteText = ""
                editingHighlight = saved
            }
            pendingSelection = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    private func commitNoteEdit(on highlight: Highlight) {
        let text = noteText
        let store = highlightStore
        Task { @MainActor in
            if let store {
                await viewModel.updateNote(
                    on: highlight,
                    note: text.isEmpty ? nil : text,
                    store: store
                )
            }
            editingHighlight = nil
        }
    }
    #endif
}

#if canImport(UIKit)
/// In-flight selection awaiting a color pick. `Identifiable` so SwiftUI
/// `.overlay` / `.sheet` can identify it.
struct SelectionContext: Identifiable {
    let id = UUID()
    let locator: EPUBHighlightLocator
    let frame: CGRect?
}
#endif
