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

    private let voicePresenter: (any ReaderVoicePresenter)?
    
    private let voiceChatTip = VoiceChatTip()
    private let readAloudTip = ReadAloudTip()

    private let readAloudParagraph: String?
    private let readAloudLocator: Locator?
    private let pdfViewMode: PDFViewModeSetting
    private let pdfViewModeBinding: Binding<PDFViewModeSetting>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.dismiss) private var dismiss

    @State private var chrome: ReaderChromeController = {

        #if DEBUG
            let uitestVisible =
                ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
            let uitestVisible = false
        #endif

        let autoHide: Duration = uitestVisible ? .seconds(86_400) : .seconds(4)

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
        voicePresenter: (any ReaderVoicePresenter)? = nil,
        readAloudParagraph: String? = nil,
        readAloudLocator: Locator? = nil,
        pdfViewMode: PDFViewModeSetting = .continuous,
        pdfViewModeBinding: Binding<PDFViewModeSetting>? = nil
    ) {
        self.viewModel = viewModel
        self.appDefaultTheme = appDefaultTheme
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.bookmarkMarkDirty = bookmarkMarkDirty
        self.onReadAloud = onReadAloud
        self.voicePresenter = voicePresenter
        self.readAloudParagraph = readAloudParagraph
        self.readAloudLocator = readAloudLocator
        self.pdfViewMode = pdfViewMode
        self.pdfViewModeBinding = pdfViewModeBinding
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

                    pageNavigator.goNext()
                case .previousPage:
                    pageNavigator.goPrev()
                }
            },

            coordinatorRef: coordinatorRef
        )
    }

    public var body: some View {
        ZStack {
            background

            #if canImport(UIKit)

         

                GeometryReader { proxy in
                    Reader
                        .onAppear { readerAreaSize = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in
                            readerAreaSize = newSize
                        }
                }
                .ignoresSafeArea(edges: readerIgnoredSafeAreaEdges)
                .padding(.top, readerMacTopTrim)
                .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

                if ReaderEdgeArrowPolicy.shouldShow(
                    idiom: UIDevice.current.userInterfaceIdiom
                ) && !(isCatalystPDF && activePDFViewMode == .continuous) {
                    HStack {
                        EPUBEdgeArrowButton(
                            systemName: "chevron.left",
                            label: "Previous page",
                            action: { pageNavigator.goPrev() }
                        )
                        Spacer()
                        EPUBEdgeArrowButton(
                            systemName: "chevron.right",
                            label: "Next page",
                            action: { pageNavigator.goNext() }
                        )
                    }
                    .padding(.horizontal, RishiSpacing.m)
                    .allowsHitTesting(true)
                }

                if let pending = pendingSelection {
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

                Text("EPUB reader requires iOS or Mac Catalyst")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
            #endif

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

            let state = epubReaderSignposter.beginInterval("reader.epub.open")
            defer {
                epubReaderSignposter.endInterval("reader.epub.open", state)
            }
            await viewModel.load()
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
            )
        ) { note in
            let delta =
                (note.userInfo?[EPUBMacCommandNotification.fontStepDelta]
                    as? Int) ?? 0
            guard delta != 0 else { return }
            var typo = viewModel.typography
            typo.fontSize = EPUBFontStepCalculator.step(
                from: typo.fontSize,
                delta: delta
            )
            viewModel.typography = typo
        }
        #if canImport(UIKit)
            .epubSpread { mode in
                currentSpread = mode
            }
            .onChange(of: viewModel.typography) { _, _ in applyPreferences() }
            .onChange(of: viewModel.theme) { _, _ in applyPreferences() }
            .onChange(of: colorScheme) { _, _ in
                guard viewModel.theme == .matchDevice else { return }
                applyPreferences()
            }
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

            //

            .readerSheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
        #endif
        #if !os(macOS) && !targetEnvironment(macCatalyst)

            //

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

        .onDisappear {

            Task { await viewModel.flush() }
        }

        .preferredColorScheme(viewModel.theme.preferredColorScheme)
    }

    private var isCatalystPDF: Bool {
        #if targetEnvironment(macCatalyst)
        return viewModel.book.formatType == .pdf
        #else
        return false
        #endif
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
        switch resolvedTheme {
        case .matchDevice: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .light: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .sepia: RishiColor.readerBackgroundSepia.ignoresSafeArea()
        case .dark: RishiColor.readerBackgroundDark.ignoresSafeArea()
        }
    }

    ///

    private var readerIgnoredSafeAreaEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
            return [.bottom, .horizontal]
        #else
            return .all
        #endif
    }

    private var readerMacTopTrim: CGFloat {
        return 0
    }

    private var readerBarColor: SwiftUI.Color {
        switch resolvedTheme {
        case .matchDevice: return RishiColor.readerBackgroundLight
        case .light: return RishiColor.readerBackgroundLight
        case .sepia: return RishiColor.readerBackgroundSepia
        case .dark: return RishiColor.readerBackgroundDark
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

        private var readAloudPresenter: ReaderReadAloudPresenter {
            ReaderReadAloudPresenter(coordinatorRef: coordinatorRef)
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
