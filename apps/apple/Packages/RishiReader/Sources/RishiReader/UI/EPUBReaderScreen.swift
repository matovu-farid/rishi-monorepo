import SwiftUI
import RishiCore
import RishiUIKit
import Foundation
#if canImport(UIKit)
import UIKit
import ReadiumShared
import ReadiumNavigator
#endif

/// Phase 12 Plan 12-01 — notification names mirrored from the rishi app's
/// `RishiCommand` enum. Raw strings MUST match
/// `rishi/rishi/Mac/RishiKeyboardCommands.swift`.
private enum EPUBMacCommandNotification {
    static let fontStep      = Notification.Name("RishiCommand.fontStep")
    static let fontStepDelta = "delta"
}

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
/// **Plan 06-06 wiring:** the toolbar's TOC / typography / theme buttons
/// now flip `showTOC` / `showTypography` / `showTheme` flags, which
/// mount ``EPUBTOCView`` / ``EPUBTypographyPicker`` / ``EPUBThemePicker``
/// as sheets. Every typography / theme / spread mutation re-submits a
/// fresh ``EPUBPreferences`` to the navigator via
/// ``EPUBPreferencesBridge`` — so the rendered page actually re-flows.
/// The iPad-landscape two-page spread is driven by
/// ``EPUBSpreadResolver`` through the `.epubSpread` modifier.
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
    /// Optional Phase 8 hook — when non-nil, the toolbar surfaces a
    /// "Read Aloud" button that invokes this closure. Wiring lives in the
    /// rishi app layer (RishiReader has no dependency on RishiAudio).
    private let onReadAloud: (() -> Void)?
    /// Plan 09-06 (CHAT-01, CHAT-05) — when non-nil, the toolbar surfaces
    /// a chat button and the selection context menu gains an "Ask about
    /// this" affordance. The reader DOES NOT import RishiChat — the
    /// presenter is the seam (`ReaderChatPresenter` protocol in this
    /// package, satisfied by `ChatPresenterImpl` at the app layer).
    private let chatPresenter: (any ReaderChatPresenter)?
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

    // 06-06 — sheet presentation + spread tracking.
    @State private var showTOC = false
    @State private var showTypography = false
    @State private var showTheme = false
    @State private var currentSpread: EPUBSpreadMode = .single
    #endif

    public init(
        viewModel: EPUBReaderViewModel,
        readerSettingsStore: (any ReaderSettingsStore)? = nil,
        highlightStore: (any HighlightStore)? = nil,
        onReadAloud: (() -> Void)? = nil,
        chatPresenter: (any ReaderChatPresenter)? = nil
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.onReadAloud = onReadAloud
        self.chatPresenter = chatPresenter
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
                    },
                    onAskAboutThis: chatPresenter.map { presenter in
                        {
                            let quote = pending.locator.text
                            pendingSelection = nil
                            coordinatorRef.coordinator?.clearSelection()
                            presenter.presentChat(
                                bookId: viewModel.book.id,
                                initialQuote: quote.isEmpty ? nil : quote
                            )
                        }
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
                    toolbar
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
            // Apply the restored settings to Readium immediately so the
            // first render uses them (font / size / line-height / theme).
            applyPreferences()
            #endif
        }
        // Phase 12 Plan 12-01 — Mac menu font-step.
        .onReceive(NotificationCenter.default.publisher(for: EPUBMacCommandNotification.fontStep)) { note in
            let delta = (note.userInfo?[EPUBMacCommandNotification.fontStepDelta] as? Int) ?? 0
            guard delta != 0 else { return }
            let current = viewModel.typography.fontSize.points
            let stepped = ReaderFontSize.clamped(current + Double(delta) * 2.0)
            var typo = viewModel.typography
            typo.fontSize = stepped
            viewModel.typography = typo
        }
        #if canImport(UIKit)
        .epubSpread { mode in
            currentSpread = mode
        }
        .onChange(of: viewModel.typography) { _, _ in applyPreferences() }
        .onChange(of: viewModel.theme) { _, _ in applyPreferences() }
        .onChange(of: currentSpread) { _, _ in applyPreferences() }
        .sheet(isPresented: $showTOC) {
            EPUBTOCView(
                entries: viewModel.publication?.manifest.tableOfContents ?? [],
                onSelect: { link in
                    showTOC = false
                    let coordinator = coordinatorRef.coordinator
                    Task { @MainActor in
                        _ = await coordinator?.go(to: link)
                    }
                },
                onClose: { showTOC = false }
            )
        }
        .sheet(isPresented: $showTypography) {
            EPUBTypographyPicker(
                typography: Binding(
                    get: { viewModel.typography },
                    set: { viewModel.typography = $0 }
                ),
                bookId: viewModel.book.id,
                store: readerSettingsStore ?? EphemeralReaderSettingsStore(),
                onClose: { showTypography = false }
            )
        }
        .sheet(isPresented: $showTheme) {
            EPUBThemePicker(
                theme: Binding(
                    get: { viewModel.theme },
                    set: { viewModel.theme = $0 }
                ),
                bookId: viewModel.book.id,
                store: readerSettingsStore ?? EphemeralReaderSettingsStore(),
                onClose: { showTheme = false }
            )
        }
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
    private var toolbar: some View {
        EPUBReaderToolbar(
            title: viewModel.title.isEmpty ? viewModel.book.title : viewModel.title,
            isPublicationLoaded: viewModel.publication != nil,
            onClose: {
                Task {
                    await viewModel.flush()
                    dismiss()
                }
            },
            onShowTOC: showTOCAction,
            onShowTheme: showThemeAction,
            onShowTypography: showTypographyAction,
            onReadAloud: onReadAloud,
            onChat: chatPresenter.map { presenter in
                { presenter.presentChat(bookId: viewModel.book.id, initialQuote: nil) }
            }
        )
    }

    // The `#if canImport(UIKit)` flag controls whether the sheet state vars
    // exist, so the toolbar's closure actions are exported through these
    // computed properties (Swift doesn't allow `#if` inside an argument list).
    private var showTOCAction: () -> Void {
        #if canImport(UIKit)
        return { showTOC = true }
        #else
        return { }
        #endif
    }

    private var showThemeAction: () -> Void {
        #if canImport(UIKit)
        return { showTheme = true }
        #else
        return { }
        #endif
    }

    private var showTypographyAction: () -> Void {
        #if canImport(UIKit)
        return { showTypography = true }
        #else
        return { }
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

    // MARK: - Preferences

    /// Translates the current `theme` + `typography` + `currentSpread`
    /// into Readium's `EPUBPreferences` and submits them through the
    /// coordinator. No-ops if the navigator hasn't built yet — the
    /// `.task` re-fires this after `load()` completes.
    private func applyPreferences() {
        coordinatorRef.coordinator?.applyPreferences(
            typography: viewModel.typography,
            theme: viewModel.theme,
            spread: currentSpread
        )
    }
    #endif
}

#if canImport(UIKit)
/// In-memory fallback used by the typography + theme pickers when no
/// `ReaderSettingsStore` is injected (previews / tests). Writes are
/// no-ops; reads always return `.default`. Mirrors the same fallback in
/// `PDFReaderScreen` (kept fileprivate per file so swapping wiring in
/// `AppDependencies` doesn't accidentally leak into production code paths).
private final class EphemeralReaderSettingsStore: ReaderSettingsStore, @unchecked Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { /* no-op */ }
    func typography(for bookId: BookID) async -> ReaderTypography { .default }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { /* no-op */ }
}
#endif

#if canImport(UIKit)
/// In-flight selection awaiting a color pick. `Identifiable` so SwiftUI
/// `.overlay` / `.sheet` can identify it.
struct SelectionContext: Identifiable {
    let id = UUID()
    let locator: EPUBHighlightLocator
    let frame: CGRect?
}
#endif

private actor EPUBPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws { }
    func delete(_ id: PositionID) async throws { }
}

@MainActor
private func makeEPUBPreviewViewModel(
    theme: ReaderTheme = .light,
    typography: ReaderTypography = .default
) -> EPUBReaderViewModel {
    let url = Bundle.module.url(forResource: "alice", withExtension: "epub")
        ?? URL(fileURLWithPath: "/dev/null")
    let book = Book(
        userId: UUID(),
        title: "Alice's Adventures in Wonderland",
        author: "Lewis Carroll",
        formatType: .epub,
        fileURL: url.path
    )
    let vm = EPUBReaderViewModel(
        book: book,
        userId: UUID(),
        documentURL: url,
        positionStore: EPUBPreviewPositionStore()
    )
    vm.theme = theme
    vm.typography = typography
    return vm
}

#Preview("Light theme") {
    EPUBReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .light))
}

#Preview("Sepia theme") {
    EPUBReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .sepia))
}

#Preview("Dark theme") {
    EPUBReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .dark))
}

#Preview("Serif large type") {
    EPUBReaderScreen(
        viewModel: makeEPUBPreviewViewModel(
            theme: .sepia,
            typography: ReaderTypography(
                fontFamily: .serif,
                fontSize: ReaderFontSize(points: 22),
                lineHeight: ReaderLineHeight(multiplier: 1.6)
            )
        )
    )
}
