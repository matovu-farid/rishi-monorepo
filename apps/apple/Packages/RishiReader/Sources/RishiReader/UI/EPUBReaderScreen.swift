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
    // Phase 37 Plan 37-06 — context-aware Mac ⌘F / ⌘D. Same literal strings as
    // the app's `RishiCommand` enum so this reader package receives the bridged
    // notifications without depending on the host target. While this screen is
    // mounted, `focusSearch` opens the in-book search sheet (reader-open wins
    // over the library search field) and `addBookmark` toggles the current
    // locator's bookmark.
    static let focusSearch   = Notification.Name("RishiCommand.focusSearch")
    static let addBookmark   = Notification.Name("RishiCommand.addBookmark")
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
        // Phase 37 Plan 37-03 — EPUB bookmark toggle + bookmarks-list buttons.
        "reader.toolbar.bookmark",
        "reader.toolbar.bookmarksList",
        // Phase 37 Plan 37-05 — EPUB in-book search button.
        "reader.toolbar.search",
        "reader.toolbar.readAloud",
        "reader.toolbar.voice",
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
    /// Phase 37 Plan 37-03 — optional injection: when `nil`, the bookmark
    /// toggle + list are inert (the toolbar buttons still render but never
    /// persist). `EPUBReaderDestination` wires `services.bookmarkStore`.
    private let bookmarkStore: (any BookmarkStore)?
    /// Phase 37-08 (BMK-05) — fired after a bookmark persist so the SyncEngine
    /// flags it dirty for outbound cross-device sync. `EPUBReaderDestination`
    /// wires `services.syncEngine.markBookmarkDirty`; `nil` leaves bookmarks
    /// local-only (tests/previews).
    private let bookmarkMarkDirty: ((BookmarkID) async -> Void)?
    /// Optional Phase 8 hook — when non-nil, the toolbar surfaces a
    /// "Read Aloud" button that invokes this closure. Wiring lives in the
    /// rishi app layer (RishiReader has no dependency on RishiAudio).
    private let onReadAloud: (() -> Void)?
    /// When non-nil, the toolbar surfaces a voice button and the selection
    /// context menu gains an "Ask about this" affordance. Voice is the
    /// primary AI surface; the quote routes into a text-chat sheet hosted
    /// inside the voice surface. The reader DOES NOT import RishiVoice — the
    /// presenter is the seam (`ReaderVoicePresenter` protocol in this
    /// package, satisfied at the app layer).
    private let voicePresenter: (any ReaderVoicePresenter)?
    /// Text of the paragraph currently being read aloud, or `nil` when no
    /// read-aloud session is active. Supplied by the app layer (RootView).
    /// The screen renders it as a Readium decoration in the `"rishi-tts"`
    /// group that follows the spoken passage.
    private let readAloudParagraph: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pops the reader back to the host NavigationStack (library) — used when
    /// the cold-open failure alert is dismissed (Phase 21 Plan 21-03 follow-up:
    /// the custom full-page failure overlay was replaced by a native `.alert`).
    @Environment(\.dismiss) private var dismiss
    /// See `PDFReaderScreen` — chrome state lives in a small `@Observable`
    /// controller so tap-to-toggle, auto-hide, and VoiceOver behavior
    /// share one tested implementation.
    @State private var chrome: ReaderChromeController = {
        // Phase 18 Plan 18-01 (F-P0-03 revert): chrome starts hidden —
        // immersive full-bleed reading. The system back chevron lives in
        // the NavigationStack and is always reachable when chrome is
        // shown. The iOS edge-swipe-from-left always pops the reader,
        // regardless of chrome state, so the user can never be trapped.
        // UI tests need the toolbar (Read Aloud button) reachable without relying
        // on a flaky webview tap-to-toggle; start chrome visible under the
        // RISHI_UITEST launch flag. DEBUG + env-gated, so never in a release.
        #if DEBUG
        let uitestVisible = ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
        let uitestVisible = false
        #endif
        // Under RISHI_UITEST keep the chrome pinned (no 4s auto-hide) so the
        // toolbar's Read Aloud button stays reachable for the whole test run.
        let autoHide: Duration = uitestVisible ? .seconds(86_400) : .seconds(4)
        // On Mac the toolbar (back button, voice chat, etc.) stays visible at
        // all times — no immersive tap-to-toggle / auto-hide like on iOS.
        #if targetEnvironment(macCatalyst)
        let alwaysVisible = true
        #else
        let alwaysVisible = false
        #endif
        #if canImport(UIKit)
        return ReaderChromeController(
            accessibility: UIKitAccessibilityProvider(),
            autoHideDelay: autoHide,
            initiallyVisible: uitestVisible,
            alwaysVisible: alwaysVisible
        )
        #else
        return ReaderChromeController(
            accessibility: PreviewAccessibility(),
            autoHideDelay: autoHide,
            initiallyVisible: uitestVisible,
            alwaysVisible: alwaysVisible
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

    /// Phase 37 Plan 37-03 — owns the bookmark set + `isBookmarked` + toggle for
    /// this book. Built lazily in `.task` once `bookmarkStore` is available
    /// (stays `nil` for previews / store-less callers). Read directly in the
    /// toolbar body (do NOT snapshot to a derived `@State` — RESEARCH Pitfall 5)
    /// so a toggle/refresh repaints the `bookmark`/`bookmark.fill` SF Symbol. The
    /// model reads the live `viewModel.latestLocator` via a closure, so the EPUB
    /// match always uses the current top-of-viewport location.
    @State private var bookmarkToggle: EPUBBookmarkToggleModel?

    /// Phase 37 Plan 37-05 — drives Readium's in-book full-text search + the
    /// jump to a chosen result. Built lazily in `.task` once
    /// `viewModel.publication` is loaded (search needs the live publication); the
    /// `.search` sheet reads it directly. Read in the toolbar/sheet body so a
    /// new result page repaints the list.
    @State private var searchModel: EPUBSearchModel?

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
        bookmarkStore: (any BookmarkStore)? = nil,
        bookmarkMarkDirty: ((BookmarkID) async -> Void)? = nil,
        onReadAloud: (() -> Void)? = nil,
        voicePresenter: (any ReaderVoicePresenter)? = nil,
        readAloudParagraph: String? = nil
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.bookmarkMarkDirty = bookmarkMarkDirty
        self.onReadAloud = onReadAloud
        self.voicePresenter = voicePresenter
        self.readAloudParagraph = readAloudParagraph
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
                        highlightInteractor.handleSelectionChange(selection)
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
                            // Phase 18 Plan 18-02 — F-P1-01: the navigator
                            // helper bumps the SwiftUI `.sensoryFeedback`
                            // trigger and drives Readium forward. Readium
                            // owns the real position; the counter is synthetic.
                            pageNavigator.goNext()
                        case .previousPage:
                            pageNavigator.goPrev()
                        }
                    },
                    onPageForward: { pageNavigator.goNext() },
                    onPageBackward: { pageNavigator.goPrev() },
                    coordinatorRef: coordinatorRef
                )
                .onAppear { readerAreaSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in readerAreaSize = newSize }
            }
            .ignoresSafeArea(edges: readerIgnoredSafeAreaEdges)
            .padding(.top, readerMacTopTrim)
            .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

            // Apple Books-style on-screen page-turn chevrons, overlaid on the
            // left & right edges. Shown on iPad + Mac only (not iPhone) and
            // ALWAYS visible — they're not tied to the chrome/toolbar state.
            // The ZStack centers the HStack vertically.
            if ReaderEdgeArrowPolicy.shouldShow(idiom: UIDevice.current.userInterfaceIdiom) {
                HStack {
                    EPUBEdgeArrowButton(systemName: "chevron.left",
                                        label: "Previous page",
                                        action: { pageNavigator.goPrev() })
                    Spacer()
                    EPUBEdgeArrowButton(systemName: "chevron.right",
                                        label: "Next page",
                                        action: { pageNavigator.goNext() })
                }
                .padding(.horizontal, RishiSpacing.m)
                .allowsHitTesting(true)
            }

            if let pending = pendingSelection {
                EPUBHighlightContextMenu(
                    selectionFrame: pending.frame,
                    onColor: { color in
                        highlightInteractor.saveHighlight(pending: pending, color: color)
                    },
                    onAddNote: {
                        highlightInteractor.startNoteFlow(for: pending)
                    },
                    onDismiss: {
                        pendingSelection = nil
                        coordinatorRef.coordinator?.clearSelection()
                    },
                    onAskAboutThis: voicePresenter.map { presenter in
                        {
                            let quote = pending.locator.text
                            pendingSelection = nil
                            coordinatorRef.coordinator?.clearSelection()
                            presenter.presentVoice(
                                bookId: viewModel.book.id,
                                context: viewModel.voiceContext(),
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
        // be empty during the loading window). The `.failed` case no longer
        // renders a custom full-page overlay; it surfaces a native `.alert`
        // (see `.readerColdOpenFailureAlert` below) that pops the reader.
        .overlay {
            switch viewModel.loadingState {
            case .idle, .loading:
                ReaderColdOpenOverlay(bookTitle: viewModel.book.title)
            case .failed, .loaded:
                EmptyView()
            }
        }
        // Phase 21 Plan 21-03 follow-up — native failure alert replaces the
        // custom full-page `ReaderColdOpenFailureOverlay`. Dismissing it pops
        // the reader back to the library via `@Environment(\.dismiss)`.
        .readerColdOpenFailureAlert(
            bookTitle: viewModel.book.title,
            reason: coldOpenFailureReason,
            onDismiss: { dismiss() }
        )
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
            // Phase 37 Plan 37-03 — build the bookmark toggle model once the
            // store is available, then hydrate `isBookmarked` for the location
            // the reader opened on. The closure reads the live locator so the
            // match never goes stale.
            if let store = bookmarkStore {
                let toggle = bookmarkToggle ?? EPUBBookmarkToggleModel(
                    store: store,
                    bookId: viewModel.book.id,
                    currentLocator: { viewModel.latestLocator },
                    markDirty: bookmarkMarkDirty
                )
                bookmarkToggle = toggle
                await toggle.refresh()
            }
            // Phase 37 Plan 37-05 — build the search model once the publication
            // is loaded (search runs against the live Readium publication). The
            // default-installed ContentSearchService makes `publication.search`
            // work with no service registration.
            if searchModel == nil, let publication = viewModel.publication {
                searchModel = EPUBSearchModel(publication: publication)
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
            var typo = viewModel.typography
            typo.fontSize = EPUBFontStepCalculator.step(from: typo.fontSize, delta: delta)
            viewModel.typography = typo
        }
        #if canImport(UIKit)
        .epubSpread { mode in
            currentSpread = mode
        }
        .onChange(of: viewModel.typography) { _, _ in applyPreferences() }
        .onChange(of: viewModel.theme) { _, _ in applyPreferences() }
        .onChange(of: currentSpread) { _, _ in applyPreferences() }
        // Read-aloud inline highlight: follow the spoken passage as the TTS
        // bridge advances. The decoration is anchored to the current resource
        // via the navigator coordinator.
        .onChange(of: readAloudParagraph) { _, _ in
            readAloudPresenter.apply(paragraph: readAloudParagraph)
        }
        // Phase 37 Plan 37-06 — context-aware Mac ⌘F: while the reader is
        // mounted over the library, intercept `focusSearch` and open the
        // in-book search sheet instead of focusing the library search field
        // (reader-open wins). The library handler still fires when no reader is
        // up. Inside the `#if canImport(UIKit)` block because `activeSheet` /
        // `bookmarkToggle` only exist there; the closure runs on the MainActor,
        // so the `activeSheet` write is in-context.
        .onReceive(NotificationCenter.default.publisher(for: EPUBMacCommandNotification.focusSearch)) { _ in
            activeSheet = .search
        }
        // Phase 37 Plan 37-06 — Mac ⌘D: toggle the current locator's bookmark
        // via the same toggle model the toolbar button uses (no-op until the
        // model is built once `bookmarkStore` is injected).
        .onReceive(NotificationCenter.default.publisher(for: EPUBMacCommandNotification.addBookmark)) { _ in
            Task { await bookmarkToggle?.toggle() }
        }
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
        .readerSheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
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
            trailingToolbarContent
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
        // Opaque, theme-matched nav-bar background. The default system bar is
        // translucent; with the page drawn under it (`.ignoresSafeArea()`), a
        // page turn briefly blanks the area behind the bar to black and the
        // translucent material samples it — a black band flashes across the
        // top. An opaque background the same color as the page makes the bar
        // seamless at rest AND keeps it solid through the animated turn, so
        // nothing black is ever revealed. Keeps Readium's slide animation.
        // Extracted into a helper so the (already large) body stays within
        // the Swift type-checker's complexity budget.
        .opaqueReaderNavBar(readerBarColor)
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
        // Drive the window appearance from the reader theme so the native
        // macOS titlebar text ("Library") stays legible. Without this the
        // titlebar follows the system light/dark trait while the page
        // background follows viewModel.theme, so a mismatch (e.g. dark
        // system + light/sepia theme) renders white title on a cream bar.
        .preferredColorScheme(viewModel.theme == .dark ? .dark : .light)
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

    /// Adds/removes a bookmark at the current locator. UIKit-gated so the macOS
    /// dev-host stub branch no-ops (Swift forbids `#if` inside a closure mounted
    /// inline on a `ToolbarItem`).
    private var bookmarkToggleAction: () -> Void {
        #if canImport(UIKit)
        return {
            chrome.userActivity()
            // KEEP: toggle is @MainActor async on the model; the store upsert/
            // delete is the only suspension point.
            Task { await bookmarkToggle?.toggle() }
        }
        #else
        return { }
        #endif
    }

    /// Refreshes the bookmark set and presents the `.bookmarks` list sheet.
    private var showBookmarksAction: () -> Void {
        #if canImport(UIKit)
        return {
            chrome.userActivity()
            Task { await bookmarkToggle?.refresh() }
            activeSheet = .bookmarks
        }
        #else
        return { }
        #endif
    }

    /// Presents the `.search` in-book search sheet. UIKit-gated so the macOS
    /// dev-host stub branch no-ops.
    private var showSearchAction: () -> Void {
        #if canImport(UIKit)
        return {
            chrome.userActivity()
            activeSheet = .search
        }
        #else
        return { }
        #endif
    }

    /// Voice opener used by the `ToolbarItem` (top-bar trailing). The
    /// selection menu's "Ask about this" affordance routes through the same
    /// presenter with a non-nil quote. Bumps chrome user-activity so the
    /// auto-hide timer resets when the user reaches for voice.
    private var voiceAction: () -> Void {
        guard let presenter = voicePresenter else {
            return { }
        }
        return {
            #if canImport(UIKit)
            chrome.userActivity()
            #endif
            presenter.presentVoice(
                bookId: viewModel.book.id,
                context: viewModel.voiceContext(),
                initialQuote: nil
            )
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

    /// Safe-area edges the reader content is allowed to bleed under.
    ///
    /// On Mac the toolbar is ALWAYS visible (chrome never auto-hides), so the
    /// page must sit below it — ignoring the top safe area would draw the first
    /// line of text under the opaque toolbar and clip it. iOS reads immersive
    /// (chrome auto-hides to overlay), so it keeps the full-bleed `.all`.
    private var readerIgnoredSafeAreaEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
        return [.bottom, .horizontal]
        #else
        return .all
        #endif
    }

    /// Mac-only upward trim of the top reading margin. Insetting below the
    /// always-on toolbar (see ``readerIgnoredSafeAreaEdges``) stacks the
    /// toolbar+titlebar safe-area inset on top of Readium's own page margin,
    /// leaving a large empty band under the toolbar. This negative top padding
    /// pulls the page back up to a comfortable margin. Tunable: make it more
    /// negative to tighten further, less to loosen. iOS keeps full-bleed, so
    /// no trim there.
    private var readerMacTopTrim: CGFloat {
        #if targetEnvironment(macCatalyst)
        return -50
        #else
        return 0
        #endif
    }

    /// Theme-matched solid color for the nav-bar background so it reads as a
    /// seamless extension of the page (no visible bar line) and never reveals
    /// the transient black behind a translucent bar during a page turn.
    private var readerBarColor: SwiftUI.Color {
        switch viewModel.theme {
        case .light: return RishiColor.readerBackgroundLight
        case .sepia: return RishiColor.readerBackgroundSepia
        case .dark:  return RishiColor.readerBackgroundDark
        }
    }

    #if !os(macOS)
    /// Whether the current locator is bookmarked. Hoisted out of the toolbar
    /// menu so the ternary labels don't compound the builder's type-checking
    /// cost.
    private var isCurrentLocatorBookmarked: Bool {
        bookmarkToggle?.isBookmarked ?? false
    }

    /// Secondary reader actions in one explicit native Menu. Extracted so the
    /// trailing toolbar builder stays within the Swift type-checker's
    /// complexity budget.
    @ViewBuilder
    private var readerMoreMenu: some View {
        Menu {
            Button(action: showTOCAction) {
                Label("Contents", systemImage: "list.bullet.indent")
            }
            .accessibilityIdentifier("reader.toolbar.toc")

            Button(action: bookmarkToggleAction) {
                Label(
                    isCurrentLocatorBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: isCurrentLocatorBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            .accessibilityIdentifier("reader.toolbar.bookmark")

            Button(action: showBookmarksAction) {
                Label("Bookmarks", systemImage: "bookmark.circle")
            }
            .accessibilityIdentifier("reader.toolbar.bookmarksList")

            Button(action: showSearchAction) {
                Label("Search", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("reader.toolbar.search")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("reader.toolbar.more")
        .accessibilityLabel("More")
    }

    /// Trailing nav-bar items (AI actions, typography, theme, overflow menu).
    /// Extracted into a dedicated `ToolbarContent` builder so the body stays
    /// within the Swift type-checker's complexity budget — the inline group
    /// failed to type-check in reasonable time under Release/WMO in CI.
    @ToolbarContentBuilder
    private var trailingToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Premium AI actions are DIRECT trailing buttons (and first) so
            // they are always visible: the app is premium-only and Read
            // Aloud / Voice Chat are flagship features.
            if onReadAloud != nil {
                Button(action: readAloudAction) {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .accessibilityIdentifier("reader.toolbar.readAloud")
                .accessibilityLabel(A11yLabel.readerReadAloud)
            }

            if voicePresenter != nil {
                Button(action: voiceAction) {
                    Image(systemName: "waveform.circle")
                }
                .accessibilityIdentifier("reader.toolbar.voice")
                .accessibilityLabel(A11yLabel.readerOpenVoice)
            }

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

            readerMoreMenu
        }
    }
    #endif

    #if canImport(UIKit)
    /// Content for the single `.readerSheet(item:)`. Extracted from `body` so
    /// the screen's modifier chain stays within the Swift type-checker's
    /// complexity budget (the inline switch tipped it over once the nav-bar
    /// background modifier was added).
    @ViewBuilder
    private func sheetContent(for sheet: ReaderSheet) -> some View {
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
        case .bookmarks:
            // Phase 37 Plan 37-03 — saved-bookmarks list (the shared
            // engine-agnostic view from 37-02). Selecting a row decodes the
            // Readium locator and jumps via the navigator's `go(to: Locator)`
            // overload; swipe-delete removes the row through the store and
            // refreshes the toggle state.
            BookmarksListView(
                bookmarks: bookmarkToggle?.bookmarks ?? [],
                onSelect: { bookmark in
                    activeSheet = nil
                    if let locator = EPUBBookmarkMatcher.locator(of: bookmark) {
                        let coordinator = coordinatorRef.coordinator
                        // KEEP: Readium navigator.go(to:) requires @MainActor.
                        Task { @MainActor in
                            _ = await coordinator?.go(to: locator)
                        }
                    }
                },
                onDelete: { bookmark in
                    Task {
                        try? await bookmarkStore?.delete(bookmark.id)
                        await bookmarkMarkDirty?(bookmark.id)
                        await bookmarkToggle?.refresh()
                    }
                },
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
                onSave: { highlightInteractor.commitNoteEdit(on: hl) },
                onCancel: { activeSheet = nil }
            )
        case .search:
            // Phase 37 Plan 37-05 — EPUB in-book search (the shared
            // engine-agnostic view from 37-04). Submitting runs Readium's
            // `publication.search`; selecting a row resolves it back to a
            // `Locator` and jumps via the navigator's `go(to: Locator)` overload.
            SearchResultsView(
                query: Binding(
                    get: { searchModel?.query ?? "" },
                    set: { searchModel?.query = $0 }
                ),
                isSearching: searchModel?.isSearching ?? false,
                rows: searchModel?.resultRows ?? [],
                onSubmit: {
                    if let model = searchModel {
                        model.search(model.query)
                    }
                },
                onSelect: { row in
                    activeSheet = nil
                    if let locator = searchModel?.locator(for: row) {
                        let coordinator = coordinatorRef.coordinator
                        // KEEP: Readium navigator.go(to:) requires @MainActor.
                        Task { @MainActor in
                            _ = await coordinator?.go(to: locator)
                        }
                    }
                },
                onClose: {
                    searchModel?.cancel()
                    activeSheet = nil
                }
            )
        }
    }
    #endif

    /// Maps `loadingState` to the cold-open failure reason: non-nil only when
    /// `load()` failed, which drives the native `.readerColdOpenFailureAlert`.
    private var coldOpenFailureReason: String? {
        if case .failed(let reason) = viewModel.loadingState {
            return reason
        }
        return nil
    }

    // MARK: - Extracted coordinators (UIKit-only)

    #if canImport(UIKit)
    /// Drives forward / backward page turns on the Readium navigator. Engine
    /// knowledge (goForward / goBackward) lives in the helper, not the view
    /// (Plan 34-03, SRP).
    private var pageNavigator: EPUBPageNavigator {
        EPUBPageNavigator(viewModel: viewModel, coordinatorRef: coordinatorRef)
    }

    /// Sequences the read-aloud follow-highlight choreography on the coordinator
    /// (Plan 34-03, SRP).
    private var readAloudPresenter: EPUBReadAloudPresenter {
        EPUBReadAloudPresenter(coordinatorRef: coordinatorRef)
    }

    /// Owns the selection -> highlight CRUD choreography. Holds bindings to the
    /// view's `@State` so the timing of each UI mutation is preserved
    /// (Plan 34-03, SRP).
    private var highlightInteractor: EPUBHighlightInteractor {
        EPUBHighlightInteractor(
            viewModel: viewModel,
            coordinatorRef: coordinatorRef,
            highlightStore: highlightStore,
            pendingSelection: $pendingSelection,
            noteText: $noteText,
            activeSheet: $activeSheet
        )
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
/// In-flight selection awaiting a color pick. `Identifiable` so SwiftUI
/// `.overlay` / `.sheet` can identify it.
struct SelectionContext: Identifiable {
    let id = UUID()
    let locator: EPUBHighlightLocator
    let frame: CGRect?
}

/// One of the two on-screen edge page-turn chevrons (iPad + Mac). Subtle
/// secondary-tinted glyph in a 44pt hit target.
private struct EPUBEdgeArrowButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(RishiColor.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private extension View {
    /// Pins an opaque, theme-matched background to the navigation bar so the
    /// translucent system bar never samples the transient black behind it
    /// during an animated page turn. Extracted from the screen's `body` so the
    /// (already large) chain stays within the Swift type-checker's budget.
    @ViewBuilder
    func opaqueReaderNavBar(_ color: SwiftUI.Color) -> some View {
        toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(Visibility.visible, for: .navigationBar)
    }
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
