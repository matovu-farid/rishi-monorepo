import SwiftUI
import RishiCore
import RishiUIKit
#if canImport(UIKit)
import UIKit
import PDFKit
#endif

/// Top-level SwiftUI screen for reading a PDF.
///
/// Composes:
///   - `PDFReaderView` (UIKit-gated PDFKit wrapper, plan 05-05)
///   - `PDFHighlightOverlay` (saved highlights as tinted rects, plan 05-06)
///   - `PDFReaderToolbar` (close + title)
///   - `PDFPageIndicator` (floating page count)
///   - `HighlightContextMenu` (4-color palette + Add Note, plan 05-06)
///   - `HighlightNoteEditor` sheet (plan 05-06)
///
/// Layered in later waves:
///   - 05-07 — TOC sheet, theme picker, library integration
///
/// macOS dev-host renders a stub label; Mac Catalyst hits the UIKit branch.
@MainActor
public struct PDFReaderScreen: View {

    private let viewModel: PDFReaderViewModel
    /// Optional injection: when `nil`, the highlight UI is mounted but never
    /// persists. Call sites in plan 05-07 will wire `GRDBHighlightStore`.
    private let highlightStore: (any HighlightStore)?
    /// Optional injection: when `nil`, theme selections are not persisted
    /// (used by tests / previews). Production wiring in 05-07 AppDependencies
    /// passes a `UserDefaultsReaderSettingsStore`.
    private let readerSettingsStore: (any ReaderSettingsStore)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible: Bool = true
    @State private var showTOC: Bool = false
    @State private var showThemePicker: Bool = false

    #if canImport(UIKit)
    // Selection coordinator state — set whenever PDFView publishes a new
    // PDFSelection. `pendingHighlight` holds the locator+text from the
    // current selection so the context menu can save it; cleared after
    // the user picks a color or dismisses.
    @State private var pendingHighlight: PendingHighlight?
    // Sheet item for the note editor; non-nil = sheet is visible.
    @State private var editingNoteOn: Highlight?
    @State private var editingNoteText: String = ""
    // Live PDFView reference, captured via `onPDFViewReady`. Used to build
    // the user-space → view-space rect mapper for the overlay.
    @State private var pdfViewRef: PDFView?
    #endif

    public init(
        viewModel: PDFReaderViewModel,
        readerSettingsStore: (any ReaderSettingsStore)? = nil,
        highlightStore: (any HighlightStore)? = nil
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
    }

    /// SwiftUI binding to the @Observable viewModel's theme. Tracks writes so
    /// the picker's `@Binding var theme` round-trips through the live VM.
    private var themeBinding: Binding<ReaderTheme> {
        Binding(
            get: { viewModel.theme },
            set: { viewModel.theme = $0 }
        )
    }

    public var body: some View {
        ZStack {
            background

            #if canImport(UIKit)
            PDFReaderView(
                viewModel: viewModel,
                onSelectionChange: { sel in
                    handleSelectionChange(sel)
                },
                onPDFViewReady: { view in
                    pdfViewRef = view
                }
            )
            .ignoresSafeArea()
            .onTapGesture {
                chromeVisible.toggle()
            }
            .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

            // Saved-highlight overlay. Renders nothing until the PDFView is
            // ready (we need it for the rect mapper).
            if let pdfView = pdfViewRef {
                PDFHighlightOverlay(
                    highlights: viewModel.highlightsForCurrentPage,
                    mapRect: { rect in
                        guard let page = pdfView.currentPage else { return .zero }
                        return pdfView.convert(rect, from: page)
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // Floating context menu for the pending selection.
            if let pending = pendingHighlight {
                VStack {
                    Spacer()
                    HighlightContextMenu(
                        onColor: { color in
                            saveHighlight(pending: pending, color: color, note: nil)
                        },
                        onAddNote: {
                            startNoteFlow(for: pending)
                        }
                    )
                    .padding(.bottom, RishiSpacing.xxl)
                }
                .transition(.opacity)
            }
            #else
            // Native macOS dev-host stub for compile-only — ship hits the
            // UIKit branch above on iOS + Mac Catalyst.
            Text("PDFReaderView is iOS / Mac Catalyst only")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            #endif

            if chromeVisible {
                VStack {
                    PDFReaderToolbar(
                        title: viewModel.book.title,
                        onClose: {
                            Task {
                                await viewModel.flush()
                                dismiss()
                            }
                        },
                        onTOC: { showTOC = true },
                        onTheme: { showThemePicker = true }
                    )
                    Spacer()
                    PDFPageIndicator(
                        currentPage: viewModel.pageIndex + 1,
                        totalPages: viewModel.totalPages
                    )
                    .padding(.bottom, RishiSpacing.m)
                }
                .transition(.opacity)
            }
        }
        .task {
            await viewModel.load()
            if let store = highlightStore {
                await viewModel.loadHighlights(from: store)
            }
            if let settings = readerSettingsStore {
                viewModel.theme = await settings.theme(for: viewModel.book.id)
            }
        }
        .sheet(isPresented: $showTOC) {
            PDFTOCView(
                nodes: viewModel.outline,
                onSelect: { pageIndex in
                    viewModel.seek(toPage: pageIndex)
                    showTOC = false
                },
                onClose: { showTOC = false }
            )
        }
        .sheet(isPresented: $showThemePicker) {
            if let settings = readerSettingsStore {
                PDFThemePicker(
                    theme: themeBinding,
                    bookId: viewModel.book.id,
                    store: settings,
                    onClose: { showThemePicker = false }
                )
            } else {
                // No store: still let the user preview themes in-session.
                PDFThemePicker(
                    theme: themeBinding,
                    bookId: viewModel.book.id,
                    store: EphemeralReaderSettingsStore(),
                    onClose: { showThemePicker = false }
                )
            }
        }
        #if canImport(UIKit)
        .sheet(item: $editingNoteOn) { highlight in
            HighlightNoteEditor(
                note: $editingNoteText,
                snippet: highlight.text,
                onSave: { commitNoteEdit(on: highlight) },
                onCancel: { editingNoteOn = nil }
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
    private func handleSelectionChange(_ selection: PDFSelection?) {
        guard let selection,
              let document = viewModel.document,
              let locator = PDFSelectionCoordinator.makeLocator(from: selection, in: document)
        else {
            pendingHighlight = nil
            return
        }
        pendingHighlight = PendingHighlight(locator: locator, text: locator.text)
    }

    private func saveHighlight(pending: PendingHighlight, color: HighlightColor, note: String?) {
        let store = highlightStore
        Task { @MainActor in
            if let store {
                _ = await viewModel.createHighlight(
                    color: color,
                    locator: pending.locator,
                    note: note,
                    store: store
                )
            }
            pendingHighlight = nil
        }
    }

    private func startNoteFlow(for pending: PendingHighlight) {
        let store = highlightStore
        Task { @MainActor in
            guard let store else {
                pendingHighlight = nil
                return
            }
            // Save first with default yellow + empty note, then open the editor
            // bound to the saved row.
            if let saved = await viewModel.createHighlight(
                color: .yellow,
                locator: pending.locator,
                note: nil,
                store: store
            ) {
                editingNoteText = ""
                editingNoteOn = saved
            }
            pendingHighlight = nil
        }
    }

    private func commitNoteEdit(on highlight: Highlight) {
        let text = editingNoteText
        let store = highlightStore
        Task { @MainActor in
            if let store {
                await viewModel.updateNote(
                    on: highlight,
                    note: text.isEmpty ? nil : text,
                    store: store
                )
            }
            editingNoteOn = nil
        }
    }
    #endif
}

#if canImport(UIKit)
/// Lightweight state struct for an unsaved selection awaiting a color pick.
struct PendingHighlight: Equatable {
    let locator: PDFHighlightLocator
    let text: String
}
#endif

/// In-memory fallback used by the theme picker when no `ReaderSettingsStore`
/// is injected (previews / tests). Writes are no-ops; reads always return
/// `.default`. Keeps the picker's contract trivially satisfiable without
/// dragging UserDefaults into preview environments.
private final class EphemeralReaderSettingsStore: ReaderSettingsStore, @unchecked Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { /* no-op */ }
}
