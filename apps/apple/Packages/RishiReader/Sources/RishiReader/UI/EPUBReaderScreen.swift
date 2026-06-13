import SwiftUI
import RishiCore
import RishiUIKit
import Foundation
import os.signpost
#if canImport(UIKit)
import UIKit
import ReadiumShared
import ReadiumNavigator
#endif

/// Phase 19 Plan 19-08 (F-P2-04) — file-static signposter so Instruments
/// Time Profiler can attribute the cost of opening an EPUB (publication
/// load, position restore, highlight hydrate, Readium preferences apply).
/// Shared with `PDFReaderScreen` / `ReaderChromeController` would have
/// blurred the category, so this and PDF each own their own signposter on
/// the `reader` category but emit distinct interval names (`reader.epub.open`
/// vs `reader.pdf.open`).
private let epubReaderSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)

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
///   - Native `.toolbar { ToolbarItemGroup(placement: .topBarTrailing) }`
///     (TOC + typography + theme + read-aloud + chat — Plan 18-07 / F-P1-05)
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

    /// Phase 18 Plan 18-07 (F-P1-05) — canonical source of truth for the
    /// accessibility identifiers attached to the buttons inside this
    /// screen's `.toolbar { ToolbarItemGroup(placement: .topBarTrailing) }`
    /// block. The runtime toolbar reads from this exact array so a drift
    /// between source-of-truth and render-time becomes a compile error.
    ///
    /// `nonisolated` because pure-data `[String]` constants don't need
    /// MainActor isolation and the test suite (default isolation
    /// `nonisolated`) reads it without an `await`.
    nonisolated public static let toolbarAccessibilityIdentifiers: [String] = [
        "reader.toolbar.toc",
        "reader.toolbar.typography",
        "reader.toolbar.theme",
        "reader.toolbar.readAloud",
        "reader.toolbar.chat",
    ]

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// See `PDFReaderScreen` — chrome state lives in a small `@Observable`
    /// controller so tap-to-toggle, auto-hide, and VoiceOver behavior
    /// share one tested implementation.
    @State private var chrome: ReaderChromeController = {
        // Phase 18 Plan 18-01 (F-P0-03 revert): chrome starts hidden —
        // immersive full-bleed reading. The system back chevron lives in
        // the NavigationStack and is always reachable when chrome is
        // shown. The iOS edge-swipe-from-left always pops the reader,
        // regardless of chrome state, so the user can never be trapped.
        #if canImport(UIKit)
        return ReaderChromeController(
            accessibility: UIKitAccessibilityProvider(),
            initiallyVisible: false
        )
        #else
        return ReaderChromeController(
            accessibility: PreviewAccessibility(),
            initiallyVisible: false
        )
        #endif
    }()

    #if canImport(UIKit)
    @State private var pendingSelection: SelectionContext?
    @State private var noteText: String = ""
    /// Lazy reference to the live navigator coordinator; populated by
    /// ``EPUBReaderView`` once Readium installs the navigator. We use
    /// it to re-apply decorations after loadHighlights / createHighlight
    /// / deleteHighlight.
    @State private var coordinatorRef = EPUBCoordinatorRef()

    /// Phase 18 Plan 18-08 (F-P2-01) — single source of truth for which
    /// content sheet is currently presented. Replaces the prior chain of
    /// `$showTOC` / `$showTypography` / `$showTheme` / `$editingHighlight`
    /// flags with a `ReaderSheet?` enum. Setting one case automatically
    /// unsets the others; setting `nil` dismisses. The paywall sheet
    /// stays SEPARATE (mounted from `RootView`) so it can fire
    /// concurrently with a content sheet here.
    @State private var activeSheet: ReaderSheet?

    @State private var currentSpread: EPUBSpreadMode = .single

    /// Live size of the reader content area; populated by the outer
    /// GeometryReader so the tap-region resolver can compute left/center/
    /// right based on actual width.
    @State private var readerAreaSize: CGSize = .zero
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
            // Outer GeometryReader feeds the tap-region resolver with the
            // live page-area size. Phase 18 Plan 18-03 (F-P1-02): the
            // engine renders directly inside this ZStack — the old
            // SwiftUI page-turn wrapper installed its own DragGesture
            // that captured horizontal swipes and never forwarded them
            // to Readium's internal paginator, so the user could not
            // swipe pages. Horizontal paging now belongs to
            // EPUBNavigatorViewController (Readium) end-to-end.
            //
            // Phase 21 fix: chrome-toggle / tap-to-page-turn taps are
            // now intercepted by a UIKit `UITapGestureRecognizer`
            // attached to the navigator's container view from
            // ``EPUBReaderView`` (cancelsTouchesInView = false +
            // shouldRecognizeSimultaneouslyWith = true). The prior
            // `Color.clear.contentShape(Rectangle())
            // .simultaneousGesture(SpatialTapGesture)` overlay sat above
            // the engine and its hit-test region claimed horizontal
            // pan touches before Readium ever saw `touchesMoved`, so
            // swipe paging was silently broken. The native UIKit
            // recognizer fails-fast on pan slop, so horizontal swipes
            // flow uninterrupted to the engine's pan recognizer.
            GeometryReader { proxy in
                EPUBReaderView(
                    viewModel: viewModel,
                    onSelectionChange: { selection in
                        handleSelectionChange(selection)
                    },
                    onTap: { location in
                        let resolver = ReaderTapRegionResolver()
                        let decision = resolver.decide(
                            at: location,
                            in: readerAreaSize
                        )
                        switch decision {
                        case .toggleChrome:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                chrome.toggle()
                            }
                        case .nextPage:
                            // Phase 18 Plan 18-02 — F-P1-01: bump
                            // the SwiftUI `.sensoryFeedback` trigger
                            // on every committed page turn. Readium
                            // owns the real position; the counter
                            // is synthetic.
                            viewModel.advancePage()
                            let navigator = coordinatorRef.coordinator?.navigator
                            // KEEP: Readium EPUBNavigatorViewController
                            // requires @MainActor; goForward is a
                            // navigator UI mutation.
                            Task { @MainActor in
                                _ = await navigator?.goForward(options: NavigatorGoOptions(animated: true))
                            }
                        case .previousPage:
                            viewModel.advancePage()
                            let navigator = coordinatorRef.coordinator?.navigator
                            // KEEP: Readium navigator UI mutation; @MainActor.
                            Task { @MainActor in
                                _ = await navigator?.goBackward(options: NavigatorGoOptions(animated: true))
                            }
                        }
                    },
                    coordinatorRef: coordinatorRef
                )
                .onAppear { readerAreaSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in readerAreaSize = newSize }
            }
            .ignoresSafeArea()
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

            if chrome.isVisible {
                VStack {
                    Spacer()
                    EPUBProgressIndicator(
                        totalProgression: viewModel.latestLocator?.locations.totalProgression
                    )
                    .padding(.bottom, RishiSpacing.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // Phase 21 Plan 21-03 — cold-open overlay. Driven off the VM's
        // `loadingState` so the user never lands on a frozen page
        // transition during the multi-second Readium ZIP unpack + parse.
        // `.idle` is treated as "still loading" — covers the brief
        // window before `.task` runs `load()` and flips state to
        // `.loading`. Uses `viewModel.book.title` (not the EPUB-only
        // `viewModel.title`, which is populated AFTER load() and would
        // be empty during the loading window).
        .overlay {
            switch viewModel.loadingState {
            case .idle, .loading:
                ReaderColdOpenOverlay(bookTitle: viewModel.book.title)
            case .failed(let reason):
                ReaderColdOpenFailureOverlay(bookTitle: viewModel.book.title, reason: reason)
            case .loaded:
                EmptyView()
            }
        }
        // Phase 18 Plan 18-02 — F-P1-01.
        // Native SwiftUI haptics. SwiftUI fires the haptic each time the
        // trigger value changes. Page-turn call sites bump
        // `currentPageIndex` (synthetic Int — EPUB has no integer
        // pages; Readium owns real position); boundary-clamp sites
        // bump `lastBoundaryHitTick`. SwiftUI gates haptics on Reduce
        // Motion automatically — no manual `.prepare()` priming, no
        // UIKit feedback-generator dance.
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.currentPageIndex)
        .sensoryFeedback(.warning, trigger: viewModel.lastBoundaryHitTick)
        #if !os(macOS)
        .statusBarHidden(!chrome.isVisible)
        .persistentSystemOverlays(chrome.isVisible ? .automatic : .hidden)
        #endif
        .task {
            // Phase 19 Plan 19-08 (F-P2-04) — wrap the EPUB open hot path
            // (publication load + theme/typography hydrate + highlight load
            // + preferences apply). Pure additive; behavior unchanged.
            let state = epubReaderSignposter.beginInterval("reader.epub.open")
            defer { epubReaderSignposter.endInterval("reader.epub.open", state) }
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
        // Phase 18 Plan 18-08 (F-P2-01) — single `.sheet(item:)` driven by
        // the `ReaderSheet?` enum replaces the prior chain of four cascading
        // `.sheet(isPresented:)` modifiers (TOC, typography, theme,
        // highlight-note editor). The paywall sheet stays SEPARATE
        // (mounted from `RootView`) and CAN fire concurrently with this
        // sheet — e.g. user taps Read Aloud while the theme picker is up
        // and an entitlement check fails. Folding the paywall in here
        // would lose that concurrency, which is why the enum deliberately
        // does NOT include a paywall case.
        //
        // The `.ttsControls` / `.ttsPicker` cases of `ReaderSheet` are
        // currently unreached on this screen — the live TTS sheets are
        // owned by `RootView`. The switch handles them with `EmptyView()`
        // so the enum invariant (exhaustive coverage) holds; the day TTS
        // migrates into this package, swap the `EmptyView()` for the real
        // sheet view and the call sites already feed the right enum case.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .toc:
                EPUBTOCView(
                    entries: viewModel.publication?.manifest.tableOfContents ?? [],
                    onSelect: { link in
                        activeSheet = nil
                        let coordinator = coordinatorRef.coordinator
                        // KEEP: Readium navigator.go(to:) requires @MainActor.
                        Task { @MainActor in
                            _ = await coordinator?.go(to: link)
                        }
                    },
                    onClose: { activeSheet = nil }
                )
            case .typography:
                EPUBTypographyPicker(
                    typography: Binding(
                        get: { viewModel.typography },
                        set: { viewModel.typography = $0 }
                    ),
                    bookId: viewModel.book.id,
                    store: readerSettingsStore ?? EphemeralReaderSettingsStore(),
                    onClose: { activeSheet = nil }
                )
            case .theme:
                EPUBThemePicker(
                    theme: Binding(
                        get: { viewModel.theme },
                        set: { viewModel.theme = $0 }
                    ),
                    bookId: viewModel.book.id,
                    store: readerSettingsStore ?? EphemeralReaderSettingsStore(),
                    onClose: { activeSheet = nil }
                )
            case .ttsControls, .ttsPicker:
                // Owned by RootView today. Placeholder keeps the
                // switch exhaustive and the enum invariant intact.
                EmptyView()
            case .highlightNote(let hl):
                HighlightNoteEditor(
                    note: $noteText,
                    snippet: hl.text,
                    onSave: { commitNoteEdit(on: hl) },
                    onCancel: { activeSheet = nil }
                )
            }
        }
        #endif
        #if !os(macOS)
        // Phase 18 Plan 18-07 (F-P1-05) — native SwiftUI toolbar replaces
        // the hand-rolled HStack overlay toolbar. Items live
        // in the system nav bar; visibility follows the chrome state via
        // the `navBarVisibility(...)` modifier below, so the system
        // bar (and these ToolbarItems with it) hide when the reader is
        // in immersive mode. Catalyst gets NSToolbar bridging for free.
        //
        // The `.bottomBar` slot is explicitly hidden because we ship no
        // bottom-bar items today and the platform would otherwise reserve
        // safe-area space for one when the nav bar is visible.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: showTOCAction) {
                    Image(systemName: "list.bullet.indent")
                }
                .accessibilityIdentifier("reader.toolbar.toc")
                .accessibilityLabel(A11yLabel.readerOpenTOC)

                Button(action: showTypographyAction) {
                    Image(systemName: "textformat.size")
                }
                .accessibilityIdentifier("reader.toolbar.typography")
                .accessibilityLabel(A11yLabel.readerOpenTypography)

                Button(action: showThemeAction) {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityIdentifier("reader.toolbar.theme")
                .accessibilityLabel(A11yLabel.readerOpenTheme)

                if onReadAloud != nil {
                    Button(action: readAloudAction) {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .accessibilityIdentifier("reader.toolbar.readAloud")
                    .accessibilityLabel(A11yLabel.readerReadAloud)
                }

                if chatPresenter != nil {
                    Button(action: chatAction) {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("reader.toolbar.chat")
                    .accessibilityLabel(A11yLabel.readerOpenChat)
                }
            }
        }
        // Phase 18 Plan 18-01 (F-P0-04) + Plan 18-07 (F-P1-05) — gate the
        // nav bar AND the bottom bar on chrome visibility. When chrome is
        // up, the system back chevron is rendered at top-left (labeled
        // "Library") and the ToolbarItemGroup above is visible at
        // top-right; when chrome is hidden, the immersive bare-page state
        // is preserved (nav bar + bottom bar collapse together). The iOS
        // edge-swipe-from-left works in BOTH states because the host
        // NavigationStack owns dismissal.
        .toolbar(navBarVisibility(forChromeVisible: chrome.isVisible), for: .navigationBar)
        .toolbar(navBarVisibility(forChromeVisible: chrome.isVisible), for: .bottomBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Flush position-store writes when this view leaves the screen,
        // regardless of whether the user used the system chevron or the
        // edge-swipe pop gesture.
        .onDisappear {
            // KEEP: viewModel.flush is @MainActor on EPUBReaderViewModel; the
            // positionStore.upsert inside is an actor method. UI-state mutation
            // (pendingPositionTask = nil) needs main; the persist step suspends
            // off-actor automatically.
            Task { await viewModel.flush() }
        }
    }

    // Phase 18 Plan 18-07 (F-P1-05) — the in-app overlay toolbar was
    // replaced by a native `.toolbar { ToolbarItemGroup }` block on the
    // screen body. See the `.toolbar { ToolbarItemGroup(placement:
    // .topBarTrailing) { … } }` modifier below for the new wiring.
    //
    // The `#if canImport(UIKit)` flag controls whether the sheet-state
    // `@State` vars exist (`showTOC`, `showTypography`, `showTheme`); on
    // the macOS dev-host stub branch the buttons no-op. Action helpers
    // are computed because Swift doesn't allow `#if` inside a closure
    // body inline-mounted on a `ToolbarItem`.
    private var showTOCAction: () -> Void {
        #if canImport(UIKit)
        return { chrome.userActivity(); activeSheet = .toc }
        #else
        return { }
        #endif
    }

    private var showThemeAction: () -> Void {
        #if canImport(UIKit)
        return { chrome.userActivity(); activeSheet = .theme }
        #else
        return { }
        #endif
    }

    private var showTypographyAction: () -> Void {
        #if canImport(UIKit)
        return { chrome.userActivity(); activeSheet = .typography }
        #else
        return { }
        #endif
    }

    /// Phase 18 Plan 18-07 (F-P1-05) — chat opener used by the
    /// `ToolbarItem` (top-bar trailing) and respected from the selection
    /// menu's "Ask about this" affordance. Mirrors the previous overlay
    /// toolbar's behavior: bumps chrome user-activity so the auto-hide
    /// timer resets when the user reaches for chat.
    private var chatAction: () -> Void {
        guard let presenter = chatPresenter else {
            return { }
        }
        return {
            #if canImport(UIKit)
            chrome.userActivity()
            #endif
            presenter.presentChat(bookId: viewModel.book.id, initialQuote: nil)
        }
    }

    /// Read-aloud closure (Phase 8 opt-in). Wraps with `chrome.userActivity()`
    /// on UIKit hosts so tapping the toolbar button postpones auto-hide.
    private var readAloudAction: () -> Void {
        guard let action = onReadAloud else {
            return { }
        }
        return {
            #if canImport(UIKit)
            chrome.userActivity()
            #endif
            action()
        }
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
            pendingSelection = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    private func startNoteFlow(for pending: SelectionContext) {
        let store = highlightStore
        // KEEP: viewModel.createHighlight is @MainActor, navigator decorations
        // are @MainActor, activeSheet is @State on this view.
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
                // Phase 18 Plan 18-08 (F-P2-01) — drive the single
                // .sheet(item:) instead of the prior dedicated
                // `editingHighlight` @State binding.
                activeSheet = .highlightNote(saved)
            }
            pendingSelection = nil
            coordinatorRef.coordinator?.clearSelection()
        }
    }

    private func commitNoteEdit(on highlight: Highlight) {
        let text = noteText
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
            // Phase 18 Plan 18-08 (F-P2-01) — dismissing the highlight
            // editor clears the single-sheet enum.
            activeSheet = nil
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
private final class EphemeralReaderSettingsStore: ReaderSettingsStore, Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { /* no-op */ }
    func typography(for bookId: BookID) async -> ReaderTypography { .default }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { /* no-op */ }
}
#endif

#if !canImport(UIKit)
/// Compile-only `AccessibilityProviding` for the macOS dev-host branch.
/// See `PDFReaderScreen.swift` for rationale.
@MainActor
private final class PreviewAccessibility: AccessibilityProviding {
    var isVoiceOverRunning: Bool { false }
}
#endif

/// Phase 21 Plan 21-03 — native SwiftUI overlay shown while the reader
/// view-model's `load()` is still resolving the publication. Uses stock
/// `ProgressView` per the Phase 18 native-UI rule; the book title is
/// the only customisation. SwiftUI gates the spinner on Reduce Motion
/// automatically — no manual handling required. File-private mirror of
/// the same struct in `PDFReaderScreen.swift` — both screens own their
/// own copy so each remains a single self-contained file.
private struct ReaderColdOpenOverlay: View {
    let bookTitle: String
    var body: some View {
        ZStack {
            RishiColor.background.opacity(0.95).ignoresSafeArea()
            VStack(spacing: RishiSpacing.m) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                Text("Opening \(bookTitle)")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(bookTitle)")
    }
}

/// Phase 21 Plan 21-03 — overlay shown when `load()` fails so the user
/// is never left on a blank screen. Native SwiftUI only.
private struct ReaderColdOpenFailureOverlay: View {
    let bookTitle: String
    let reason: String
    var body: some View {
        ZStack {
            RishiColor.background.ignoresSafeArea()
            VStack(spacing: RishiSpacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(RishiColor.textPrimary)
                Text("Could not open \(bookTitle)")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                Text(reason)
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Could not open \(bookTitle). \(reason)")
    }
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
