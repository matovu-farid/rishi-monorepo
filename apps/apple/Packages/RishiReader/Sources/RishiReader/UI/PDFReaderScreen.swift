import SwiftUI
import RishiCore
import RishiUIKit
import Foundation
import os.signpost
#if canImport(UIKit)
import UIKit
import PDFKit
#endif

/// Phase 19 Plan 19-08 (F-P2-04) — file-static signposter so Instruments
/// Time Profiler can attribute the cost of opening a PDF (document load
/// + outline parse + highlight hydrate + theme restore). Distinct from
/// the EPUB signposter by interval name (`reader.pdf.open` vs
/// `reader.epub.open`) so traces remain grep-able.
private let pdfReaderSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)

/// Phase 12 Plan 12-01 — notification names mirrored from the rishi app's
/// `RishiCommand` enum so the reader package can subscribe without
/// depending on the host target. Raw string values MUST match the app's
/// declaration in `rishi/rishi/Mac/RishiKeyboardCommands.swift`.
private enum ReaderMacCommandNotification {
    static let pageForward    = Notification.Name("RishiCommand.pageForward")
    static let pageBackward   = Notification.Name("RishiCommand.pageBackward")
    static let fontStep       = Notification.Name("RishiCommand.fontStep")
    static let fontStepDelta  = "delta"
}

/// Top-level SwiftUI screen for reading a PDF.
///
/// Composes:
///   - `PDFReaderView` (UIKit-gated PDFKit wrapper, plan 05-05)
///   - `PDFHighlightOverlay` (saved highlights as tinted rects, plan 05-06)
///   - Native `.toolbar { ToolbarItemGroup(placement: .topBarTrailing) }`
///     (TOC + theme + read-aloud + chat — Plan 18-07 / F-P1-05)
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

    /// Phase 18 Plan 18-07 (F-P1-05) — canonical source of truth for the
    /// accessibility identifiers attached to the buttons inside this
    /// screen's `.toolbar { ToolbarItemGroup(placement: .topBarTrailing) }`
    /// block. PDF has no typography button — PDFKit owns font/zoom
    /// controls via its native gestures and the platform menu.
    ///
    /// `nonisolated` because pure-data `[String]` constants don't need
    /// MainActor isolation and the test suite (default isolation
    /// `nonisolated`) reads it without an `await`.
    nonisolated public static let toolbarAccessibilityIdentifiers: [String] = [
        "reader.toolbar.toc",
        "reader.toolbar.theme",
        "reader.toolbar.bookmark",
        "reader.toolbar.bookmarksList",
        "reader.toolbar.search",
        "reader.toolbar.readAloud",
        "reader.toolbar.voice",
    ]

    private let viewModel: PDFReaderViewModel
    /// Optional injection: when `nil`, the highlight UI is mounted but never
    /// persists. Call sites in plan 05-07 will wire `GRDBHighlightStore`.
    private let highlightStore: (any HighlightStore)?
    /// Phase 37 Plan 37-02 — optional injection: when `nil`, the bookmark
    /// toggle + list are inert (the toolbar buttons still render but never
    /// persist). `PDFReaderDestination` wires `services.bookmarkStore`.
    private let bookmarkStore: (any BookmarkStore)?
    /// Optional injection: when `nil`, theme selections are not persisted
    /// (used by tests / previews). Production wiring in 05-07 AppDependencies
    /// passes a `UserDefaultsReaderSettingsStore`.
    private let readerSettingsStore: (any ReaderSettingsStore)?
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
    /// read-aloud session is active. Supplied by the app layer (RootView)
    /// which owns the TTS bridge + paragraph list. The screen renders it as
    /// an inline `PDFView.highlightedSelections` highlight that follows the
    /// spoken passage page-to-page.
    private let readAloudParagraph: String?
    /// Phase 31 — the LIVE user-facing PDF view-mode setting. Mac-only: the
    /// `resolvedLayoutMode` resolver consults it under `macCatalyst`; iOS never
    /// reads it (its `#else` reader block ignores `layoutMode` entirely). Plan
    /// 31-04 supplies this value from the `@Observable` `AppReaderDefaults` at
    /// the construction site (`PDFReaderDestination`), so reading it inside the
    /// SwiftUI body triggers invalidation on a Settings change — applies live
    /// (RESEARCH Pitfall 5: do NOT snapshot it to `@State`). Defaults to
    /// `.automatic` so previews / pre-31-04 callers compile unchanged.
    private let pdfViewMode: PDFViewModeSetting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pops the reader back to the host NavigationStack (library) — used when
    /// the cold-open failure alert is dismissed (Phase 21 Plan 21-03 follow-up:
    /// the custom full-page failure overlay was replaced by a native `.alert`).
    @Environment(\.dismiss) private var dismiss
    /// Chrome visibility is owned by a small `@Observable` controller so
    /// the tap-to-toggle, auto-hide, and VoiceOver behaviors live in a
    /// single testable seam (see `ReaderChromeController`).
    @State private var chrome: ReaderChromeController = {
        // Phase 18 Plan 18-01 (F-P0-03 revert): chrome starts hidden —
        // immersive full-bleed reading. The system back chevron lives in
        // the NavigationStack and is always reachable when chrome is
        // shown. The iOS edge-swipe-from-left always pops the reader,
        // regardless of chrome state, so the user can never be trapped.
        // UI tests need the toolbar (Read Aloud button) reachable without relying
        // on a tap-to-toggle; start chrome visible under the RISHI_UITEST launch
        // flag. DEBUG + env-gated, so never in a release. Mirrors EPUBReaderScreen.
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

    /// Phase 18 Plan 18-08 (F-P2-01) — single source of truth for which
    /// content sheet is currently presented. Replaces the prior chain of
    /// `$showTOC` / `$showThemePicker` / `$editingNoteOn` flags with a
    /// `ReaderSheet?` enum. Setting one case automatically unsets the
    /// others; setting `nil` dismisses. The paywall sheet stays SEPARATE
    /// (mounted from `RootView`) so it can fire concurrently with a
    /// content sheet here.
    @State private var activeSheet: ReaderSheet?

    /// Phase 37 Plan 37-02 — owns the bookmark set + `isBookmarked` + toggle for
    /// this book. Built lazily in `.task` once `bookmarkStore` is available
    /// (stays `nil` for previews / store-less callers). Read directly in the
    /// toolbar body (do NOT snapshot to a derived `@State` — RESEARCH Pitfall 5)
    /// so a toggle/refresh repaints the `bookmark`/`bookmark.fill` SF Symbol.
    @State private var bookmarkToggle: PDFBookmarkToggleModel?

    /// Phase 37 Plan 37-04 — owns the PDFKit incremental-search state for this
    /// book. Read directly by the `.search` sheet (query / isSearching /
    /// resultRows) so a new match repaints the results `List`. Engine-agnostic
    /// rows feed the shared ``SearchResultsView``.
    @State private var searchModel = PDFSearchModel()

    #if canImport(UIKit)
    // Selection coordinator state — set whenever PDFView publishes a new
    // PDFSelection. `pendingHighlight` holds the locator+text from the
    // current selection so the context menu can save it; cleared after
    // the user picks a color or dismisses.
    @State private var pendingHighlight: PendingHighlight?
    @State private var editingNoteText: String = ""
    // Live PDFView reference, captured via `onPDFViewReady`. Used to build
    // the user-space → view-space rect mapper for the overlay.
    @State private var pdfViewRef: PDFView?

    /// Live size of the reader content area; populated by the outer
    /// GeometryReader so the tap-region resolver can compute left/center/
    /// right based on actual width.
    @State private var readerAreaSize: CGSize = .zero

    /// Phase 30 / Phase 31 — resolved Mac PDF layout mode. The full-screen
    /// scene probe + resolution math live in ``PDFMacLayoutResolver`` (plan
    /// 34-02); the view just reads the resolved value. Reading the
    /// `@Observable`-backed `pdfViewMode` here means a Settings change applies
    /// live (RESEARCH Pitfall 5). Only the `#if targetEnvironment(macCatalyst)`
    /// branch inside ``PDFReaderView`` acts on the result; the iOS path ignores
    /// `layoutMode`, so iOS rendering stays byte-identical regardless of value.
    private var resolvedLayoutMode: PDFReaderLayoutMode {
        PDFMacLayoutResolver.resolvedLayoutMode(
            pdfViewMode: pdfViewMode,
            readerAreaSize: readerAreaSize
        )
    }
    #endif

    public init(
        viewModel: PDFReaderViewModel,
        readerSettingsStore: (any ReaderSettingsStore)? = nil,
        highlightStore: (any HighlightStore)? = nil,
        bookmarkStore: (any BookmarkStore)? = nil,
        onReadAloud: (() -> Void)? = nil,
        voicePresenter: (any ReaderVoicePresenter)? = nil,
        readAloudParagraph: String? = nil,
        pdfViewMode: PDFViewModeSetting = .automatic
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.onReadAloud = onReadAloud
        self.voicePresenter = voicePresenter
        self.readAloudParagraph = readAloudParagraph
        self.pdfViewMode = pdfViewMode
    }

    /// Phase 34 Plan 34-02 — the single page-navigation state machine. Collapses
    /// the three previously-duplicated next/prev/clamp blocks (tap, Mac
    /// `pageForward`, Mac `pageBackward`) into one tested ``PDFPageNavigator``.
    private var navigator: PDFPageNavigator {
        PDFPageNavigator(viewModel: viewModel)
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
            // Outer GeometryReader feeds the tap-region resolver with the
            // live page-area size. Phase 18 Plan 18-03 (F-P1-02): the
            // engine renders directly inside this ZStack — the old
            // SwiftUI page-turn wrapper installed its own DragGesture
            // that captured horizontal swipes and never forwarded them
            // to PDFKit's `UIPageViewController`, so the user could not
            // swipe pages. Horizontal paging now belongs to PDFKit
            // (`PDFView.usePageViewController(true)`) end-to-end.
            //
            // Phase 21 fix: chrome-toggle / tap-to-page-turn taps are
            // now intercepted by a UIKit `UITapGestureRecognizer`
            // attached directly to the `PDFView` from ``PDFReaderView``
            // (cancelsTouchesInView = false +
            // shouldRecognizeSimultaneouslyWith = true). The prior
            // `Color.clear.contentShape(Rectangle())
            // .simultaneousGesture(SpatialTapGesture)` overlay sat
            // above the PDF and its hit-test region claimed horizontal
            // pan touches before PDFKit ever saw `touchesMoved`, so
            // swipe paging was silently broken. The native UIKit
            // recognizer fails-fast on pan slop so horizontal swipes
            // flow uninterrupted to PDFKit's pan recognizer.
            GeometryReader { proxy in
                PDFReaderView(
                    viewModel: viewModel,
                    layoutMode: resolvedLayoutMode,
                    onSelectionChange: { sel in
                        handleSelectionChange(sel)
                    },
                    onPDFViewReady: { view in
                        pdfViewRef = view
                        applyReadAloudHighlight()
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
                            navigator.goNext()
                        case .previousPage:
                            navigator.goPrev()
                        }
                    }
                )
                // Phase 31 — parent `.id()` rebuild token (pre-resolved
                // decision #2, LOCKED). `usePageViewController(true)` is a sticky
                // one-way scroller swap with no documented off-toggle (RESEARCH
                // Pitfall 1 / Open Q1), so crossing the Single Page boundary must
                // produce a FRESH `makeUIView` rather than an in-place
                // reconfigure. Keying the id on whether the effective mode is
                // `.singlePage` recreates the PDFView when entering/leaving Single
                // Page, while Continuous <-> Two Page keep the SAME id and use
                // plan 31-02's Phase-30 in-place reconfigure. Coordinates with
                // 31-02's `updateUIView` rebuild, which fires ONLY for a live
                // transition on an already-realized view (`oldMode != nil`): a
                // fresh `makeUIView` from this `.id()` change lands with
                // `appliedLayoutMode == nil`, so it takes the plain configure path
                // and never double-rebuilds. The VM (`viewModel.pageIndex`)
                // preserves reading position across the fresh make.
                .id(resolvedLayoutMode == .singlePage ? "pdf-singlePage" : "pdf-scrolling")
                .onAppear { readerAreaSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in readerAreaSize = newSize }
            }
            .ignoresSafeArea()
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
                        },
                        onAskAboutThis: voicePresenter.map { presenter in
                            {
                                let quote = pending.text
                                pendingHighlight = nil
                                presenter.presentVoice(
                                    bookId: viewModel.book.id,
                                    context: viewModel.voiceContext(),
                                    initialQuote: quote.isEmpty ? nil : quote
                                )
                            }
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

            if chrome.isVisible {
                VStack {
                    Spacer()
                    PDFPageIndicator(
                        currentPage: viewModel.pageIndex + 1,
                        totalPages: viewModel.totalPages
                    )
                    .padding(.bottom, RishiSpacing.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // Phase 21 Plan 21-03 — cold-open overlay. Driven off the VM's
        // `loadingState` so the user never lands on a blank white page
        // during the multi-second `PDFDocument(url:)` parse. `.idle`
        // is treated as "still loading" — covers the brief window
        // before `.task` runs `load()` and flips state to `.loading`.
        // The `.failed` case no longer renders a custom full-page overlay;
        // it surfaces a native `.alert` (see `.readerColdOpenFailureAlert`
        // below) that pops the reader on dismiss.
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
        // `currentPageIndex` (a synthetic Int counter on the VM —
        // distinct from `pageIndex`, which tracks the PDF page) and
        // boundary-clamp sites bump `lastBoundaryHitTick`. SwiftUI
        // gates haptics on Reduce Motion automatically — no manual
        // `.prepare()` priming, no UIKit feedback-generator dance.
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.currentPageIndex)
        .sensoryFeedback(.warning, trigger: viewModel.lastBoundaryHitTick)
        #if !os(macOS)
        .statusBarHidden(!chrome.isVisible)
        .persistentSystemOverlays(chrome.isVisible ? .automatic : .hidden)
        #endif
        .task {
            // Phase 19 Plan 19-08 (F-P2-04) — wrap the PDF open hot path
            // (document load + highlights hydrate + theme restore). Pure
            // additive; behavior unchanged.
            let state = pdfReaderSignposter.beginInterval("reader.pdf.open")
            defer { pdfReaderSignposter.endInterval("reader.pdf.open", state) }
            await viewModel.load()
            if let store = highlightStore {
                await viewModel.loadHighlights(from: store)
            }
            if let settings = readerSettingsStore {
                viewModel.theme = await settings.theme(for: viewModel.book.id)
            }
            // Phase 37 Plan 37-02 — build the bookmark toggle model once the
            // store is available, then hydrate `isBookmarked` for the page the
            // reader opened on.
            if let store = bookmarkStore {
                let toggle = bookmarkToggle ?? PDFBookmarkToggleModel(
                    store: store,
                    bookId: viewModel.book.id
                )
                bookmarkToggle = toggle
                await toggle.refresh(currentPage: viewModel.pageIndex)
            }
        }
        // Phase 30 plan 30-05 — Mac Catalyst window minimum-width clamp. Scoped
        // to the reader (RESEARCH recommendation: PDFReaderScreen.onAppear, not
        // global). minWidth defaults to PDFReaderLayoutMetrics.minPageWidth so it
        // can never desync from the resolver's breakpoint. No-op on iOS.
        .onAppear {
            #if targetEnvironment(macCatalyst)
            PDFMacWindowSizing.applyMinWindowWidth()
            #endif
        }
        #if canImport(UIKit)
        // Read-aloud inline highlight: follow the spoken passage as the TTS
        // bridge advances (paragraph text changes) and re-resolve it after a
        // page turn (the selection is page-scoped).
        .onChange(of: readAloudParagraph) { _, _ in applyReadAloudHighlight() }
        .onChange(of: viewModel.pageIndex) { _, _ in applyReadAloudHighlight() }
        #endif
        // Phase 37 Plan 37-02 — re-derive the bookmark fill state when the page
        // changes (swipe, tap, TOC/bookmark jump) so the toolbar SF Symbol
        // reflects whether the now-current page is bookmarked.
        .onChange(of: viewModel.pageIndex) { _, newPage in
            Task { await bookmarkToggle?.refresh(currentPage: newPage) }
        }
        // Phase 12 Plan 12-01 — Mac menu arrow paging.
        // Phase 18 Plan 18-02 (F-P1-01) — bump the haptic trigger
        // counters so `.sensoryFeedback` fires from Mac arrow keys too.
        .onReceive(NotificationCenter.default.publisher(for: ReaderMacCommandNotification.pageForward)) { _ in
            navigator.goNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderMacCommandNotification.pageBackward)) { _ in
            navigator.goPrev()
        }
        // Phase 18 Plan 18-08 (F-P2-01) — single `.sheet(item:)` driven by
        // the `ReaderSheet?` enum replaces the prior chain of three
        // cascading `.sheet(isPresented:)` modifiers (TOC, theme picker,
        // highlight-note editor). The paywall sheet stays SEPARATE
        // (mounted from `RootView`) and CAN fire concurrently with this
        // sheet — e.g. user taps Read Aloud while the theme picker is up
        // and an entitlement check fails. Folding the paywall in here
        // would lose that concurrency, which is why the enum deliberately
        // does NOT include a paywall case.
        //
        // The `.typography` / `.ttsControls` / `.ttsPicker` cases of
        // `ReaderSheet` are unreachable on the PDF screen: PDFKit owns
        // typography via its native gestures + platform menu; the live
        // TTS sheets are owned by `RootView`. The switch handles them
        // with `EmptyView()` so the enum invariant (exhaustive coverage)
        // holds.
        .readerSheet(item: $activeSheet) { sheet in
            switch sheet {
            case .toc:
                PDFTOCView(
                    nodes: viewModel.outline,
                    onSelect: { pageIndex in
                        viewModel.seek(toPage: pageIndex)
                        activeSheet = nil
                    },
                    onClose: { activeSheet = nil }
                )
            case .theme:
                if let settings = readerSettingsStore {
                    PDFThemePicker(
                        theme: themeBinding,
                        bookId: viewModel.book.id,
                        store: settings,
                        onClose: { activeSheet = nil }
                    )
                } else {
                    // No store: still let the user preview themes in-session.
                    PDFThemePicker(
                        theme: themeBinding,
                        bookId: viewModel.book.id,
                        store: EphemeralReaderSettingsStore(),
                        onClose: { activeSheet = nil }
                    )
                }
            case .bookmarks:
                // Phase 37 Plan 37-02 — saved-bookmarks list. Selecting a row
                // decodes the page from the locator and jumps via the same
                // `seek(toPage:)` the TOC sheet uses; swipe-delete removes the
                // row through the store and refreshes the toggle state.
                BookmarksListView(
                    bookmarks: bookmarkToggle?.bookmarks ?? [],
                    onSelect: { bookmark in
                        if let page = PDFBookmarkMatcher.page(of: bookmark) {
                            viewModel.seek(toPage: page)
                        }
                        activeSheet = nil
                    },
                    onDelete: { bookmark in
                        Task {
                            try? await bookmarkStore?.delete(bookmark.id)
                            await bookmarkToggle?.refresh(currentPage: viewModel.pageIndex)
                        }
                    },
                    onClose: { activeSheet = nil }
                )
            case .search:
                // Phase 37 Plan 37-04 — in-book PDFKit search. Submitting the
                // query runs `beginFindString` off-main; selecting a result
                // jumps + highlights the match via the stored `PDFSelection`
                // and seeks the page so the indicator + read-aloud cursor
                // follow.
                SearchResultsView(
                    query: Binding(
                        get: { searchModel.query },
                        set: { searchModel.query = $0 }
                    ),
                    isSearching: searchModel.isSearching,
                    rows: searchModel.resultRows,
                    onSubmit: {
                        if let doc = viewModel.document {
                            searchModel.search(searchModel.query, in: doc)
                        }
                    },
                    onSelect: { row in
                        #if canImport(UIKit)
                        if let result = searchModel.result(for: row), let pdfView = pdfViewRef {
                            searchModel.jump(to: result, in: pdfView)
                            viewModel.seek(toPage: result.page)
                        }
                        #else
                        if let result = searchModel.result(for: row) {
                            viewModel.seek(toPage: result.page)
                        }
                        #endif
                        activeSheet = nil
                    },
                    onClose: {
                        searchModel.cancel()
                        activeSheet = nil
                    }
                )
            case .typography, .ttsControls, .ttsPicker:
                // Unreachable for PDF — PDFKit owns typography; TTS sheets
                // are owned by RootView. Placeholder keeps the switch
                // exhaustive and the enum invariant intact.
                EmptyView()
            case .highlightNote(let highlight):
                #if canImport(UIKit)
                HighlightNoteEditor(
                    note: $editingNoteText,
                    snippet: highlight.text,
                    onSave: { commitNoteEdit(on: highlight) },
                    onCancel: { activeSheet = nil }
                )
                #else
                EmptyView()
                #endif
            }
        }
        #if !os(macOS)
        // Phase 18 Plan 18-07 (F-P1-05) — native SwiftUI toolbar replaces
        // the hand-rolled HStack overlay toolbar. Items live
        // in the system nav bar; visibility follows the chrome state via
        // the `navBarVisibility(...)` modifier below, so the system bar
        // (and these ToolbarItems with it) hide when the reader is in
        // immersive mode. Catalyst gets NSToolbar bridging for free.
        //
        // The `.bottomBar` slot is explicitly hidden because we ship no
        // bottom-bar items today and the platform would otherwise reserve
        // safe-area space for one when the nav bar is visible.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    chrome.userActivity()
                    activeSheet = .toc
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .accessibilityIdentifier("reader.toolbar.toc")
                .accessibilityLabel(A11yLabel.readerOpenTOC)

                Button {
                    chrome.userActivity()
                    activeSheet = .theme
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityIdentifier("reader.toolbar.theme")
                .accessibilityLabel(A11yLabel.readerOpenTheme)

                // Phase 37 Plan 37-02 — bookmark toggle. Filled SF Symbol when
                // the current page is bookmarked; tapping adds/removes via the
                // toggle model (persisted through `bookmarkStore`).
                Button {
                    chrome.userActivity()
                    Task {
                        await bookmarkToggle?.toggle(
                            currentPage: viewModel.pageIndex,
                            snippet: nil
                        )
                    }
                } label: {
                    Image(systemName: (bookmarkToggle?.isBookmarked ?? false) ? "bookmark.fill" : "bookmark")
                }
                .accessibilityIdentifier("reader.toolbar.bookmark")
                .accessibilityLabel(A11yLabel.readerToggleBookmark)

                // Phase 37 Plan 37-02 — open the saved-bookmarks list sheet.
                Button {
                    chrome.userActivity()
                    Task { await bookmarkToggle?.refresh(currentPage: viewModel.pageIndex) }
                    activeSheet = .bookmarks
                } label: {
                    Image(systemName: "bookmark.circle")
                }
                .accessibilityIdentifier("reader.toolbar.bookmarksList")
                .accessibilityLabel(A11yLabel.readerOpenBookmarks)

                // Phase 37 Plan 37-04 — open the in-book search sheet.
                Button {
                    chrome.userActivity()
                    activeSheet = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityIdentifier("reader.toolbar.search")
                .accessibilityLabel(A11yLabel.readerSearch)

                if let onReadAloud {
                    Button {
                        chrome.userActivity()
                        onReadAloud()
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .accessibilityIdentifier("reader.toolbar.readAloud")
                    .accessibilityLabel(A11yLabel.readerReadAloud)
                }

                if let voicePresenter {
                    Button {
                        chrome.userActivity()
                        voicePresenter.presentVoice(
                            bookId: viewModel.book.id,
                            context: viewModel.voiceContext(),
                            initialQuote: nil
                        )
                    } label: {
                        Image(systemName: "waveform.circle")
                    }
                    .accessibilityIdentifier("reader.toolbar.voice")
                    .accessibilityLabel(A11yLabel.readerOpenVoice)
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
            // KEEP: viewModel.flush is @MainActor but the underlying
            // positionStore.upsert is an actor method; outer Task chains the
            // await. Final mutation of pendingPositionTask is on main, which
            // is correct since the VM itself is @MainActor.
            Task { await viewModel.flush() }
        }
        // Drive the window appearance from the reader theme so the native
        // macOS titlebar text ("Library") stays legible. Without this the
        // titlebar follows the system light/dark trait while the page
        // background follows viewModel.theme, so a mismatch (e.g. dark
        // system + light/sepia theme) renders white title on a cream bar.
        .preferredColorScheme(viewModel.theme == .dark ? .dark : .light)
    }

    @ViewBuilder
    private var background: some View {
        switch viewModel.theme {
        case .light: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .sepia: RishiColor.readerBackgroundSepia.ignoresSafeArea()
        case .dark:  RishiColor.readerBackgroundDark.ignoresSafeArea()
        }
    }

    /// Maps `loadingState` to the cold-open failure reason: non-nil only when
    /// `load()` failed, which drives the native `.readerColdOpenFailureAlert`.
    private var coldOpenFailureReason: String? {
        if case .failed(let reason) = viewModel.loadingState {
            return reason
        }
        return nil
    }

    // MARK: - Selection / highlight flow (UIKit-only)

    #if canImport(UIKit)
    /// Resolves `readAloudParagraph` to a tinted `PDFView.highlightedSelections`
    /// passage and drives Mac auto-scroll via ``PDFReadAloudPresenter`` (plan
    /// 34-02). The view just wires the live `pdfViewRef`, paragraph text, and
    /// resolved layout mode; all PDFKit/geometry work lives in the presenter.
    private func applyReadAloudHighlight() {
        readAloudPresenter.apply(
            paragraph: readAloudParagraph,
            on: pdfViewRef,
            mode: resolvedLayoutMode
        )
    }

    /// Orchestrates highlight CRUD through ``PDFHighlightInteractor`` (plan
    /// 34-02). The interactor owns the `await viewModel.create/updateHighlight`
    /// choreography; the view retains `@State` ownership and just applies the
    /// returned outcomes.
    private var highlightInteractor: PDFHighlightInteractor {
        PDFHighlightInteractor(viewModel: viewModel, highlightStore: highlightStore)
    }

    private var readAloudPresenter: PDFReadAloudPresenter { PDFReadAloudPresenter() }

    private func handleSelectionChange(_ selection: PDFSelection?) {
        pendingHighlight = highlightInteractor.pendingHighlight(for: selection)
    }

    private func saveHighlight(pending: PendingHighlight, color: HighlightColor, note: String?) {
        let interactor = highlightInteractor
        Task { @MainActor in
            await interactor.save(pending: pending, color: color, note: note)
            pendingHighlight = nil
        }
    }

    private func startNoteFlow(for pending: PendingHighlight) {
        let interactor = highlightInteractor
        Task { @MainActor in
            if let saved = await interactor.startNoteFlow(for: pending) {
                editingNoteText = ""
                // Phase 18 Plan 18-08 (F-P2-01) — drive the single
                // .sheet(item:) instead of the prior dedicated
                // `editingNoteOn` @State binding.
                activeSheet = .highlightNote(saved)
            }
            pendingHighlight = nil
        }
    }

    private func commitNoteEdit(on highlight: Highlight) {
        let text = editingNoteText
        let interactor = highlightInteractor
        Task { @MainActor in
            await interactor.commitNote(on: highlight, text: text)
            // Phase 18 Plan 18-08 (F-P2-01) — dismissing the highlight
            // editor clears the single-sheet enum.
            activeSheet = nil
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

private actor PDFPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws { }
    func delete(_ id: PositionID) async throws { }
}

@MainActor
private func makePDFPreviewViewModel(theme: ReaderTheme = .light) -> PDFReaderViewModel {
    let url = Bundle.module.url(forResource: "sample", withExtension: "pdf")
        ?? URL(fileURLWithPath: "/dev/null")
    let book = Book(
        userId: UUID(),
        title: "Sample PDF",
        author: "Preview Author",
        formatType: .pdf,
        fileURL: url.path
    )
    let vm = PDFReaderViewModel(
        book: book,
        userId: UUID(),
        documentURL: url,
        positionStore: PDFPreviewPositionStore()
    )
    vm.theme = theme
    return vm
}

#Preview("Light theme") {
    PDFReaderScreen(viewModel: makePDFPreviewViewModel(theme: .light))
}

#Preview("Sepia theme") {
    PDFReaderScreen(viewModel: makePDFPreviewViewModel(theme: .sepia))
}

#Preview("Dark theme") {
    PDFReaderScreen(viewModel: makePDFPreviewViewModel(theme: .dark))
}
