import Foundation
import TipKit


import SwiftUI
import os.signpost
import ReadiumShared

#if canImport(UIKit)
    import UIKit
    import ReadiumNavigator
#endif

private let epubReaderSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)

private enum EPUBMacCommandNotification {
    static let fontStep = Notification.Name("RishiCommand.fontStep")
    static let fontStepDelta = "delta"

    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
    static let addBookmark = Notification.Name("RishiCommand.addBookmark")
}


@MainActor
public struct ReaderScreen: View {

  

    nonisolated public static let toolbarAccessibilityIdentifiers: [String] = [
        "reader.toolbar.toc",
        "reader.toolbar.typography",
        "reader.toolbar.theme",

        "reader.toolbar.bookmark",
        "reader.toolbar.bookmarksList",

        "reader.toolbar.search",
        "reader.toolbar.readAloud",
        "reader.toolbar.voice",
    ]

    private let viewModel: ReaderViewModel

    private let appDefaultTheme: ReaderTheme

    private let readerSettingsStore: (any ReaderSettingsStore)?

    private let highlightStore: (any HighlightStore)?

    private let bookmarkStore: (any BookmarkStore)?

    private let bookmarkMarkDirty: ((BookmarkID) async -> Void)?

    private let onReadAloud: (() -> Void)?
    private let onReadAloudFrom: ((Locator) -> Void)?
    private let onFirstContentReady: @MainActor () async -> Void
    private let onLoadFailed: @MainActor () async -> Void

    private let voicePresenter: (any ReaderVoicePresenter)?
    
    private let voiceChatTip = VoiceChatTip()
    private let readAloudTip = ReadAloudTip()

    private let readAloudParagraph: String?
    private let readAloudLocator: Locator?
    private let reservedPlayerHeight: CGFloat
    private let pdfViewMode: PDFViewModeSetting
    private let pdfViewModeBinding: Binding<PDFViewModeSetting>?
    private let keepChromeVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.dismiss) private var dismiss

    @State private var chrome: ReaderChromeController

    static let readerChromeInitialAutoHideDelay: Duration = .seconds(15)
    static let readerChromeAutoHideDelay: Duration = .seconds(4)
    static let readerChromeInitiallyVisible = true
    static let readerToolbarContentBuffer: CGFloat = 0

    private static func makeChrome(
        keepVisible: Bool,
        isEPUB: Bool
    ) -> ReaderChromeController {
        #if DEBUG
            let uitestVisible =
                ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
            let uitestVisible = false
        #endif

        let autoHide: Duration = uitestVisible ? .seconds(86_400) : Self.readerChromeAutoHideDelay
        let initialAutoHide: Duration = uitestVisible
            ? .seconds(86_400)
            : Self.readerChromeInitialAutoHideDelay

        #if targetEnvironment(macCatalyst)
            let alwaysVisible = true
        #else
            let alwaysVisible = keepVisible || isEPUB
        #endif
        #if canImport(UIKit)
            return ReaderChromeController(
                accessibility: UIKitAccessibilityProvider(),
                autoHideDelay: autoHide,
                initialAutoHideDelay: initialAutoHide,
                initiallyVisible: Self.readerChromeInitiallyVisible || uitestVisible || keepVisible,
                alwaysVisible: alwaysVisible
            )
        #else
            return ReaderChromeController(
                accessibility: PreviewAccessibility(),
                autoHideDelay: autoHide,
                initialAutoHideDelay: initialAutoHide,
                initiallyVisible: Self.readerChromeInitiallyVisible || uitestVisible || keepVisible,
                alwaysVisible: alwaysVisible
            )
        #endif
    }

    #if canImport(UIKit)
        @State private var pendingSelection: SelectionContext?
        @State private var noteText: String = ""

        @State private var coordinatorRef = ReaderCoordinatorRef()

        @State private var activeSheet: ReaderSheet?

        @State private var bookmarkToggle: EPUBBookmarkToggleModel?

        @State private var searchModel: EPUBSearchModel?

        @State private var currentSpread: EPUBSpreadMode = .single

        @State private var readerAreaSize: CGSize = .zero
    #endif

    public init(
        viewModel: ReaderViewModel,
        appDefaultTheme: ReaderTheme = .default,
        readerSettingsStore: (any ReaderSettingsStore)? = nil,
        highlightStore: (any HighlightStore)? = nil,
        bookmarkStore: (any BookmarkStore)? = nil,
        bookmarkMarkDirty: ((BookmarkID) async -> Void)? = nil,
        onReadAloud: (() -> Void)? = nil,
        onReadAloudFrom: ((Locator) -> Void)? = nil,
        onFirstContentReady: @escaping @MainActor () async -> Void = {},
        onLoadFailed: @escaping @MainActor () async -> Void = {},
        voicePresenter: (any ReaderVoicePresenter)? = nil,
        readAloudParagraph: String? = nil,
        readAloudLocator: Locator? = nil,
        reservedPlayerHeight: CGFloat = 0,
        pdfViewMode: PDFViewModeSetting = .continuous,
        pdfViewModeBinding: Binding<PDFViewModeSetting>? = nil,
        keepChromeVisible: Bool = false
    ) {
        self.viewModel = viewModel
        self.appDefaultTheme = appDefaultTheme
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.bookmarkMarkDirty = bookmarkMarkDirty
        self.onReadAloudFrom = onReadAloudFrom
        self.onReadAloud = onReadAloud
        self.onFirstContentReady = onFirstContentReady
        self.onLoadFailed = onLoadFailed
        self.voicePresenter = voicePresenter
        self.readAloudParagraph = readAloudParagraph
        self.readAloudLocator = readAloudLocator
        self.reservedPlayerHeight = max(0, reservedPlayerHeight)
        self.pdfViewMode = pdfViewMode
        self.pdfViewModeBinding = pdfViewModeBinding
        self.keepChromeVisible = keepChromeVisible
        self._chrome = State(
            initialValue: Self.makeChrome(
                keepVisible: keepChromeVisible,
                isEPUB: viewModel.book.formatType == .epub
            )
        )
    }

    private var activePDFViewMode: PDFViewModeSetting {
        pdfViewModeBinding?.wrappedValue ?? pdfViewMode
    }

    private var resolvedTheme: ReaderTheme {
        viewModel.theme.resolved(isDark: colorScheme == .dark)
    }

    private var Reader: some View {
        ReaderView(
            viewModel: viewModel,
            pageTheme: resolvedTheme,
            pdfViewMode: activePDFViewMode,
            pdfViewModeBinding: pdfViewModeBinding,
            onSelectionChange: { selection in
                highlightInteractor.handleSelectionChange(selection)
            },
            onPageLocationChange: showChromeAfterPageLocationChange,
            onPageForward: goForward,
            onPageBackward: goBackward,
            onEscape: dismissPendingSelection,
            onFirstContentReady: onFirstContentReady,
            onTap: { location in
                let resolver = ReaderTapRegionResolver()
                let decision = resolver.decide(
                    at: location,
                    in: readerAreaSize,
                    allowsPageNavigation: allowsTapPageNavigation
                )
                switch decision {
                case .toggleChrome:
                    withAnimation(.easeInOut(duration: 0.25)) {
                        chrome.toggle()
                    }
                case .nextPage:
                    goForward()
                case .previousPage:
                    goBackward()
                case .ignored:
                    break
                }
            },

            coordinatorRef: coordinatorRef
        )
    }

    public var body: some View {
        readerScreenBody
    }

    private var readerScreenBody: some View {
        ZStack {
            background

            readerPlatformLayer

            progressIndicatorLayer
        }

        #if !os(macOS) && !targetEnvironment(macCatalyst)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(
                        height: isEPUBReader && chrome.isVisible
                            ? Self.readerToolbarContentBuffer
                            : 0
                    )
                    .allowsHitTesting(false)
            }

            .safeAreaInset(edge: .bottom, spacing: 0) {
                if readerPlayerInsetHeight > 0 {
                    readerContentBackground
                        .frame(height: readerPlayerInsetHeight)
                        .allowsHitTesting(false)
                }
            }
        #endif

        .overlay {
            switch viewModel.loadingState {
            case .idle, .loading:
                ReaderColdOpenOverlay(bookTitle: viewModel.book.title)
            case .failed, .loaded:
                EmptyView()
            }
        }

        .readerColdOpenFailureAlert(
            bookTitle: viewModel.book.title,
            reason: coldOpenFailureReason,
            onDismiss: { dismiss() }
        )

        .sensoryFeedback(
            .impact(weight: .light),
            trigger: viewModel.currentPageIndex
        )
        .sensoryFeedback(.warning, trigger: viewModel.lastBoundaryHitTick)
        #if !os(macOS) && !targetEnvironment(macCatalyst)
            .statusBarHidden(!chrome.isVisible)
            .persistentSystemOverlays(chrome.isVisible ? .automatic : .hidden)
        #endif
        .task {
            if viewModel.book.formatType == .pdf {
                let state = epubReaderSignposter.beginInterval("reader.pdf.load")
                await viewModel.load()
                epubReaderSignposter.endInterval("reader.pdf.load", state)
            } else {
                let state = epubReaderSignposter.beginInterval("reader.epub.load")
                await viewModel.load()
                epubReaderSignposter.endInterval("reader.epub.load", state)
            }
            if case .failed = viewModel.loadingState {
                await onLoadFailed()
            }
            let enrichmentState = epubReaderSignposter.beginInterval("reader.enrichment")
            defer {
                epubReaderSignposter.endInterval("reader.enrichment", enrichmentState)
            }
            if let settings = readerSettingsStore {
                if await settings.persistedTheme(for: viewModel.book.id) == nil {
                    await settings.setTheme(appDefaultTheme, for: viewModel.book.id)
                }
                viewModel.typography = await settings.typography(
                    for: viewModel.book.id
                )
            }
            #if canImport(UIKit)
                if let store = highlightStore {
                    await viewModel.loadHighlights(from: store)
                    coordinatorRef.coordinator?.applyHighlights(
                        viewModel.loadedHighlights
                    )
                }

                if let store = bookmarkStore {
                    let toggle =
                        bookmarkToggle
                        ?? EPUBBookmarkToggleModel(
                            store: store,
                            bookId: viewModel.book.id,
                            currentLocator: { viewModel.latestLocator },
                            markDirty: bookmarkMarkDirty
                        )
                    bookmarkToggle = toggle
                    await toggle.refresh()
                }

                if searchModel == nil, let publication = viewModel.publication {
                    searchModel = EPUBSearchModel(publication: publication)
                }

                applyPreferences()
            #endif
        }

        .onReceive(
            NotificationCenter.default.publisher(
                for: EPUBMacCommandNotification.fontStep
            ),
            perform: handleFontStepNotification
        )
        #if canImport(UIKit)
            .epubSpread { mode in
                currentSpread = mode
            }
            .onChange(of: viewModel.typography) { _, _ in applyPreferences() }
            .onChange(of: viewModel.theme) { _, _ in applyPreferences() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .rishiReaderThemeChanged
                )
            ) { note in
                guard let theme = note.object as? ReaderTheme else { return }
                viewModel.theme = theme
            }
            .onChange(of: colorScheme) { _, _ in applyPreferencesForColorSchemeChange() }
            .onChange(of: currentSpread) { _, _ in applyPreferences() }

            .onChange(of: readAloudParagraph) { _, _ in
                readAloudPresenter.apply(
                    paragraph: readAloudParagraph,
                    locator: readAloudLocator
                )
            }

            .onChange(of: readAloudLocator) { _, _ in
                readAloudPresenter.follow(locator: readAloudLocator)
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: EPUBMacCommandNotification.focusSearch
                )
            ) { _ in
                activeSheet = .search
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: EPUBMacCommandNotification.addBookmark
                )
            ) { _ in
                Task { await bookmarkToggle?.toggle() }
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: RishiCommand.pageForward
                ),
                perform: handlePageForwardCommand
            )

            .onReceive(
                NotificationCenter.default.publisher(
                    for: RishiCommand.pageBackward
                ),
                perform: handlePageBackwardCommand
            )

            .readerSheet(item: $activeSheet, content: sheetContent)
        #endif
        #if !os(macOS) && !targetEnvironment(macCatalyst)

            .toolbar {
                trailingToolbarContent
            }

            .toolbar(
                navBarVisibility(forChromeVisible: chrome.isVisible),
                for: .navigationBar
            )
            .toolbar(
                navBarVisibility(forChromeVisible: chrome.isVisible),
                for: .bottomBar
            )
            .readerNavBarAppearance(readerBarColor)
            .navigationTitle(viewModel.book.title)
            .navigationBarTitleDisplayMode(.inline)
        #endif

        #if targetEnvironment(macCatalyst)
            .safeAreaInset(edge: .top, spacing: 0) {
                CatalystReaderToolbar(title: viewModel.book.title) {
                    if onReadAloud != nil {
                        Button(action: readAloudAction) { Image(systemName: "speaker.wave.2.fill") }
                            .popoverTip(readAloudTip)
                            .accessibilityIdentifier("reader.toolbar.readAloud")
                            .accessibilityLabel(A11yLabel.readerReadAloud)
                    }
                    if voicePresenter != nil {
                        Button(action: voiceAction) { Image(systemName: "waveform.circle.fill") }
                            .popoverTip(voiceChatTip)
                            .accessibilityIdentifier("reader.toolbar.voice")
                            .accessibilityLabel(A11yLabel.readerOpenVoice)
                    }
                    Button(action: showTypographyAction) { Image(systemName: "textformat.size") }
                        .accessibilityIdentifier("reader.toolbar.typography")
                        .accessibilityLabel(A11yLabel.readerOpenTypography)
                    Button(action: showThemeAction) { Image(systemName: "circle.lefthalf.filled") }
                        .accessibilityIdentifier("reader.toolbar.theme")
                        .accessibilityLabel(A11yLabel.readerOpenTheme)
                    readerMoreMenu
                }
            }
        #endif

        .preferredColorScheme(viewModel.theme.preferredColorScheme)
    }

    private var isCatalystPDF: Bool {
        #if targetEnvironment(macCatalyst)
            return viewModel.book.formatType == .pdf
        #else
            return false
        #endif
    }

    private var isEPUBReader: Bool {
        viewModel.book.formatType == .epub
    }

    private var readerPlayerInsetHeight: CGFloat {
        guard isEPUBReader, reservedPlayerHeight > 0 else { return 0 }
        return reservedPlayerHeight + RishiSpacing.m
    }

    private func handleFontStepNotification(_ note: Notification) {
        let delta =
            (note.userInfo?[EPUBMacCommandNotification.fontStepDelta] as? Int) ?? 0
        guard delta != 0 else { return }
        var typography = viewModel.typography
        typography.fontSize = EPUBFontStepCalculator.step(
            from: typography.fontSize,
            delta: delta
        )
        viewModel.typography = typography
    }

    private func handlePageForwardCommand(_ note: Notification) {
        guard activeSheet == nil, pageCommandTargetsThisReader(note) else { return }
        coordinatorRef.coordinator?.handleArrowKey(.arrowRight)
    }

    private func handlePageBackwardCommand(_ note: Notification) {
        guard activeSheet == nil, pageCommandTargetsThisReader(note) else { return }
        coordinatorRef.coordinator?.handleArrowKey(.arrowLeft)
    }

    private func pageCommandTargetsThisReader(_ note: Notification) -> Bool {
        #if targetEnvironment(macCatalyst)
            guard let targetBookID = note.userInfo?[RishiCommand.targetBookIDKey] as? BookID else {
                return false
            }
            return targetBookID == viewModel.book.id
        #else
            return true
        #endif
    }

    @ViewBuilder
    private var readerPlatformLayer: some View {
        #if canImport(UIKit)
            GeometryReader { proxy in
                readerGeometryContent(in: proxy)
            }
            .ignoresSafeArea(edges: readerIgnoredSafeAreaEdges)
            .padding(.top, readerMacTopTrim)
            .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

            pendingSelectionOverlay

            if shouldShowEdgeArrows {
                HStack {
                    EPUBEdgeArrowButton(
                        systemName: "chevron.left",
                        label: "Previous page",
                        action: goBackward
                    )
                    Spacer()
                    EPUBEdgeArrowButton(
                        systemName: "chevron.right",
                        label: "Next page",
                        action: goForward
                    )
                }
                .padding(.horizontal, RishiSpacing.m)
                .allowsHitTesting(true)
                .zIndex(1)
            }
        #else
            Text("EPUB reader requires iOS or Mac Catalyst")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
        #endif
    }

    @ViewBuilder
    private var progressIndicatorLayer: some View {
        if chrome.isVisible {
            VStack {
                Spacer()
                EPUBProgressIndicator(
                    totalProgression: viewModel.latestLocator?.locations
                        .totalProgression
                )
                .padding(.bottom, RishiSpacing.m)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }


    //

    private var showTOCAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()
                activeSheet = .toc
            }
        #else
            return {}
        #endif
    }

    private var showThemeAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()
                activeSheet = .theme
            }
        #else
            return {}
        #endif
    }

    private var showTypographyAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()
                activeSheet = .typography
            }
        #else
            return {}
        #endif
    }

    private var bookmarkToggleAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()

                Task { await bookmarkToggle?.toggle() }
            }
        #else
            return {}
        #endif
    }

    private var showBookmarksAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()
                Task { await bookmarkToggle?.refresh() }
                activeSheet = .bookmarks
            }
        #else
            return {}
        #endif
    }

    private var showSearchAction: () -> Void {
        #if canImport(UIKit)
            return {
                chrome.userActivity()
                activeSheet = .search
            }
        #else
            return {}
        #endif
    }

    private var voiceAction: () -> Void {
        guard let presenter = voicePresenter else {
            return {}
        }
        return {
            #if canImport(UIKit)
                chrome.userActivity()
            #endif
            presenter.presentVoice(
                bookId: viewModel.book.id,
                context: viewModel.voiceContext(),
                contextProvider: { await viewModel.liveVoiceContext() },
                initialQuote: nil
            )
        }
    }

    private var readAloudAction: () -> Void {
        guard let action = onReadAloud else {
            return {}
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
        readerSurfaceColor.ignoresSafeArea()
    }

    ///

    private var readerIgnoredSafeAreaEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
            return [.bottom, .horizontal]
        #else
            return isEPUBReader ? [.horizontal] : .all
        #endif
    }

    private var readerMacTopTrim: CGFloat {
        return 0
    }

    private var readerBarColor: SwiftUI.Color {
        readerSurfaceColor
    }

    private var readerContentBackground: SwiftUI.Color {
        readerSurfaceColor
    }

    private var readerSurfaceColor: SwiftUI.Color {
        switch resolvedTheme {
        case .matchDevice, .light:
            return isEPUBReader ? .white : RishiColor.readerBackgroundLight
        case .sepia:
            return RishiColor.readerBackgroundSepia
        case .dark:
            return RishiColor.readerBackgroundDark
        }
    }

    #if !os(macOS)

        private var isCurrentLocatorBookmarked: Bool {
            bookmarkToggle?.isBookmarked ?? false
        }

        @ViewBuilder
        private var readerMoreMenu: some View {
            Menu {
                Button(action: showTOCAction) {
                    Label("Contents", systemImage: "list.bullet.indent")
                }
                .accessibilityIdentifier("reader.toolbar.toc")

                Button(action: bookmarkToggleAction) {
                    Label(
                        isCurrentLocatorBookmarked
                            ? "Remove Bookmark" : "Add Bookmark",
                        systemImage: isCurrentLocatorBookmarked
                            ? "bookmark.fill" : "bookmark"
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

        @ToolbarContentBuilder
        private var trailingToolbarContent: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {

                if onReadAloud != nil {
              
               
                        Button(action: readAloudAction) {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .popoverTip(readAloudTip)
                        .accessibilityIdentifier("reader.toolbar.readAloud")
                        .accessibilityLabel(A11yLabel.readerReadAloud)
                    
                }

                if voicePresenter != nil {
               
                        Button(action: voiceAction) {
                            Image(systemName: "waveform.circle.fill")
                        }
                        .popoverTip(voiceChatTip)
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

        @ViewBuilder
        private func sheetContent(for sheet: ReaderSheet) -> some View {
            switch sheet {
            case .toc:
                ReaderTOCView(
                    entries: viewModel.publication?.manifest.tableOfContents
                        ?? [],
                    onSelect: { link in
                        activeSheet = nil
                        let coordinator = coordinatorRef.coordinator

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
                    store: readerSettingsStore
                        ?? EphemeralReaderSettingsStore(),
                    onClose: { activeSheet = nil }
                )
            case .theme:
                EPUBThemePicker(
                    theme: Binding(
                        get: { viewModel.theme },
                        set: { viewModel.theme = $0 }
                    ),
                    bookId: viewModel.book.id,
                    store: readerSettingsStore
                        ?? EphemeralReaderSettingsStore(),
                    onClose: { activeSheet = nil }
                )
            case .bookmarks:

                BookmarksListView(
                    bookmarks: bookmarkToggle?.bookmarks ?? [],
                    onSelect: { bookmark in
                        activeSheet = nil
                        if let locator = EPUBBookmarkMatcher.locator(
                            of: bookmark
                        ) {
                            let coordinator = coordinatorRef.coordinator

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

                EmptyView()
            case .highlightNote(let hl):
                HighlightNoteEditor(
                    note: $noteText,
                    snippet: hl.text,
                    onSave: { highlightInteractor.commitNoteEdit(on: hl) },
                    onCancel: { activeSheet = nil }
                )
            case .search:

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

    private var coldOpenFailureReason: String? {
        if case .failed(let reason) = viewModel.loadingState {
            return reason
        }
        return nil
    }

    #if canImport(UIKit)

        private var pageNavigator: ReaderPageNavigator {
            ReaderPageNavigator(
                viewModel: viewModel,
                coordinatorRef: coordinatorRef
            )
        }

        private var shouldShowEdgeArrows: Bool {
            #if targetEnvironment(macCatalyst)
            ReaderEdgeArrowPolicy.shouldShow(
                idiom: UIDevice.current.userInterfaceIdiom
            ) && !(isCatalystPDF && activePDFViewMode == .continuous)
            #else
            false
            #endif
        }

        private var allowsTapPageNavigation: Bool {
            #if targetEnvironment(macCatalyst)
            true
            #else
            false
            #endif
        }

        private func readerGeometryContent(in proxy: GeometryProxy) -> some View {
            Reader
                .onAppear { readerAreaSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in
                    readerAreaSize = newSize
                }
        }

        @ViewBuilder
        private func pendingSelectionMenu(for pending: SelectionContext) -> some View {
            EPUBHighlightContextMenu(
                selectionFrame: pending.frame,
                onColor: { color in
                    highlightInteractor.saveHighlight(
                        pending: pending,
                        color: color
                    )
                },
                onAddNote: {
                    highlightInteractor.startNoteFlow(for: pending)
                },
                onDismiss: {
                    pendingSelection = nil
                    coordinatorRef.coordinator?.clearSelection()
                },
                onAskAboutThis: askAboutThisAction(for: pending),
                onReadAloudFrom: readAloudFromAction(for: pending)
            )
            .transition(.opacity)
        }

        @ViewBuilder
        private var pendingSelectionOverlay: some View {
            if let pending = pendingSelection {
                pendingSelectionMenu(for: pending)
            }
        }

        private var readAloudPresenter: ReaderReadAloudPresenter {
            ReaderReadAloudPresenter(coordinatorRef: coordinatorRef)
        }

        private func goForward() {
            dismissPendingSelection()
            pageNavigator.goNext()
        }

        private func goBackward() {
            dismissPendingSelection()
            pageNavigator.goPrev()
        }

        private func showChromeAfterPageLocationChange() {
            withAnimation(.easeInOut(duration: 0.25)) {
                chrome.show()
            }
        }

        @discardableResult
        private func dismissPendingSelection() -> Bool {
            guard pendingSelection != nil else { return false }
            pendingSelection = nil
            coordinatorRef.coordinator?.clearSelection()
            return true
        }

        private func askAboutThisAction(for pending: SelectionContext) -> (() -> Void)? {
            guard let presenter = voicePresenter else { return nil }
            let bookId = viewModel.book.id
            let context = viewModel.voiceContext()
            let quote = pending.locator.text
            let contextProvider: ReaderVoiceContextProvider = { [viewModel] in
                try await viewModel.liveVoiceContext()
            }
            return { [coordinatorRef, context, contextProvider, bookId, quote] in
                pendingSelection = nil
                coordinatorRef.coordinator?.clearSelection()
                presenter.presentVoice(
                    bookId: bookId,
                    context: context,
                    contextProvider: contextProvider,
                    initialQuote: quote.isEmpty ? nil : quote
                )
            }
        }

        private func readAloudFromAction(for pending: SelectionContext) -> (() -> Void)? {
            guard let onReadAloudFrom,
                  let locator = pending.locator.toReadiumLocator() else {
                return nil
            }
            return { [coordinatorRef, locator] in
                pendingSelection = nil
                coordinatorRef.coordinator?.clearSelection()
                onReadAloudFrom(locator)
            }
        }

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

        private func applyPreferences() {
            coordinatorRef.coordinator?.applyPreferences(
                typography: viewModel.typography,
                theme: resolvedTheme,
                spread: currentSpread
            )
        }

        private func applyPreferencesForColorSchemeChange() {
            guard viewModel.theme == .matchDevice else { return }
            applyPreferences()
        }
    #endif
}

#if canImport(UIKit)

    struct SelectionContext: Identifiable {
        let id = UUID()
        let locator: EPUBHighlightLocator
        let frame: CGRect?
    }

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

    extension View {

        @ViewBuilder
        fileprivate func readerNavBarAppearance(_ color: SwiftUI.Color) -> some View {
            #if targetEnvironment(macCatalyst)
            toolbarBackground(.bar, for: .navigationBar)
                .toolbarBackground(Visibility.visible, for: .navigationBar)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 1)
                        .shadow(
                            color: Color.black.opacity(0.14),
                            radius: 3,
                            y: 2
                        )
                        .accessibilityHidden(true)
                }
            #else
            toolbarBackground(color, for: .navigationBar)
                .toolbarBackground(Visibility.visible, for: .navigationBar)
            #endif
        }
    }
#endif

private actor EPUBPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

@MainActor
private func makeEPUBPreviewViewModel(
    theme: ReaderTheme = .light,
    typography: ReaderTypography = .default
) -> ReaderViewModel {
    let url =
        AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub")
        ?? URL(fileURLWithPath: "/dev/null")
    let book = Book(
        userId: UUID(),
        title: "Alice's Adventures in Wonderland",
        author: "Lewis Carroll",
        formatType: .epub,
        fileURL: url.path
    )
    let vm = ReaderViewModel(
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
    ReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .light))
}

#Preview("Sepia theme") {
    ReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .sepia))
}

#Preview("Dark theme") {
    ReaderScreen(viewModel: makeEPUBPreviewViewModel(theme: .dark))
}

#Preview("Serif large type") {
    ReaderScreen(
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
