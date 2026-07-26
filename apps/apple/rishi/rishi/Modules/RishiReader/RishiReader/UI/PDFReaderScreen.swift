import Foundation


import SwiftUI
import os.signpost

#if canImport(UIKit)
    import UIKit
    import PDFKit
#endif

private let pdfReaderSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)

private enum ReaderMacCommandNotification {
    static let pageForward = Notification.Name("RishiCommand.pageForward")
    static let pageBackward = Notification.Name("RishiCommand.pageBackward")
    static let fontStep = Notification.Name("RishiCommand.fontStep")
    static let fontStepDelta = "delta"

    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
    static let addBookmark = Notification.Name("RishiCommand.addBookmark")
}

@MainActor
public struct PDFReaderScreen: View {

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

    private let highlightStore: (any HighlightStore)?

    private let bookmarkStore: (any BookmarkStore)?

    private let bookmarkMarkDirty: ((BookmarkID) async -> Void)?

    private let readerSettingsStore: (any ReaderSettingsStore)?

    private let onReadAloud: (() -> Void)?

    private let voicePresenter: (any ReaderVoicePresenter)?

    private let readAloudParagraph: String?
    

    private let pdfViewMode: PDFViewModeSetting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    @State private var activeSheet: ReaderSheet?

    @State private var bookmarkToggle: PDFBookmarkToggleModel?

    @State private var searchModel = PDFSearchModel()

    #if canImport(UIKit)

        @State private var pendingHighlight: PendingHighlight?
        @State private var editingNoteText: String = ""

        @State private var pdfViewRef: PDFView?

        @State private var readerAreaSize: CGSize = .zero

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
        bookmarkMarkDirty: ((BookmarkID) async -> Void)? = nil,
        onReadAloud: (() -> Void)? = nil,
        voicePresenter: (any ReaderVoicePresenter)? = nil,
        readAloudParagraph: String? = nil,
        pdfViewMode: PDFViewModeSetting = .automatic
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.bookmarkMarkDirty = bookmarkMarkDirty
        self.onReadAloud = onReadAloud
        self.voicePresenter = voicePresenter
        self.readAloudParagraph = readAloudParagraph
        self.pdfViewMode = pdfViewMode
    }

    private var navigator: PDFPageNavigator {
        PDFPageNavigator(viewModel: viewModel)
    }

    private var themeBinding: Binding<ReaderTheme> {
        Binding(
            get: { viewModel.theme },
            set: { viewModel.theme = $0 }
        )
    }
    private var readerChrome: some View { GeometryReader { proxy in
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
        
        .id(
            resolvedLayoutMode == .singlePage
            ? "pdf-singlePage" : "pdf-scrolling"
        )
        .onAppear { readerAreaSize = proxy.size }
        .onChange(of: proxy.size) { _, newSize in
            readerAreaSize = newSize
        }
    }}
    private var reader: some View {
        ZStack {
            background

            #if canImport(UIKit)

                

               readerChrome
                .ignoresSafeArea()
                .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)

                if let pdfView = pdfViewRef {
                    PDFHighlightOverlay(
                        highlights: viewModel.highlightsForCurrentPage,
                        mapRect: { rect in
                            guard let page = pdfView.currentPage else {
                                return .zero
                            }
                            return pdfView.convert(rect, from: page)
                        }
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                if let pending = pendingHighlight {
                    VStack {
                        Spacer()
                        HighlightContextMenu(
                            onColor: { color in
                                saveHighlight(
                                    pending: pending,
                                    color: color,
                                    note: nil
                                )
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
                                        initialQuote: quote.isEmpty
                                            ? nil : quote
                                    )
                                }
                            }
                        )
                        .padding(.bottom, RishiSpacing.xxl)
                    }
                    .transition(.opacity)
                }
            #else

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
    }

    public var body: some View {
        reader

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
            #if !os(macOS)
                .statusBarHidden(!chrome.isVisible)
                .persistentSystemOverlays(
                    chrome.isVisible ? .automatic : .hidden
                )
            #endif
            .task {

                let state = pdfReaderSignposter.beginInterval("reader.pdf.open")
                defer {
                    pdfReaderSignposter.endInterval("reader.pdf.open", state)
                }
                await viewModel.load()
                if let store = highlightStore {
                    await viewModel.loadHighlights(from: store)
                }
                if let settings = readerSettingsStore {
                    viewModel.theme = await settings.theme(
                        for: viewModel.book.id
                    )
                }

                if let store = bookmarkStore {
                    let toggle =
                        bookmarkToggle
                        ?? PDFBookmarkToggleModel(
                            store: store,
                            bookId: viewModel.book.id,
                            markDirty: bookmarkMarkDirty
                        )
                    bookmarkToggle = toggle
                    await toggle.refresh(currentPage: viewModel.pageIndex)
                }
            }

            .onAppear {
                #if targetEnvironment(macCatalyst)
                    PDFMacWindowSizing.applyMinWindowWidth()
                #endif
            }
            #if canImport(UIKit)

                .onChange(of: readAloudParagraph) { _, _ in
                    applyReadAloudHighlight()
                }
                .onChange(of: viewModel.pageIndex) { _, _ in
                    applyReadAloudHighlight()
                }
            #endif

            .onChange(of: viewModel.pageIndex) { _, newPage in
                Task { await bookmarkToggle?.refresh(currentPage: newPage) }
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: ReaderMacCommandNotification.pageForward
                )
            ) { _ in
                navigator.goNext()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ReaderMacCommandNotification.pageBackward
                )
            ) { _ in
                navigator.goPrev()
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: ReaderMacCommandNotification.focusSearch
                )
            ) { _ in
                activeSheet = .search
            }

            .onReceive(
                NotificationCenter.default.publisher(
                    for: ReaderMacCommandNotification.addBookmark
                )
            ) { _ in
                Task {
                    await bookmarkToggle?.toggle(
                        currentPage: viewModel.pageIndex,
                        snippet: nil
                    )
                }
            }

            //

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

                        PDFThemePicker(
                            theme: themeBinding,
                            bookId: viewModel.book.id,
                            store: EphemeralReaderSettingsStore(),
                            onClose: { activeSheet = nil }
                        )
                    }
                case .bookmarks:

                    BookmarksListView(
                        bookmarks: bookmarkToggle?.bookmarks ?? [],
                        onSelect: { bookmark in
                            if let page = PDFBookmarkMatcher.page(of: bookmark)
                            {
                                viewModel.seek(toPage: page)
                            }
                            activeSheet = nil
                        },
                        onDelete: { bookmark in
                            Task {
                                try? await bookmarkStore?.delete(bookmark.id)
                                await bookmarkMarkDirty?(bookmark.id)
                                await bookmarkToggle?.refresh(
                                    currentPage: viewModel.pageIndex
                                )
                            }
                        },
                        onClose: { activeSheet = nil }
                    )
                case .search:

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
                                if let result = searchModel.result(for: row),
                                    let pdfView = pdfViewRef
                                {
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
        


            .readerToolBar(
                onReadAloud: onReadAloud,
                chrome: chrome,
                voicePresenter: voicePresenter, viewModel: viewModel, activeSheet: $activeSheet, bookmarkToggle: $bookmarkToggle)
               
    

     
    }

    @ViewBuilder
    private var background: some View {
        switch viewModel.theme {
        case .matchDevice: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .light: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .sepia: RishiColor.readerBackgroundSepia.ignoresSafeArea()
        case .dark: RishiColor.readerBackgroundDark.ignoresSafeArea()
        }
    }

    private var coldOpenFailureReason: String? {
        if case .failed(let reason) = viewModel.loadingState {
            return reason
        }
        return nil
    }

    #if canImport(UIKit)

        private func applyReadAloudHighlight() {
            readAloudPresenter.apply(
                paragraph: readAloudParagraph,
                on: pdfViewRef,
                mode: resolvedLayoutMode
            )
        }

        private var highlightInteractor: PDFHighlightInteractor {
            PDFHighlightInteractor(
                viewModel: viewModel,
                highlightStore: highlightStore
            )
        }

        private var readAloudPresenter: PDFReadAloudPresenter {
            PDFReadAloudPresenter()
        }

        private func handleSelectionChange(_ selection: PDFSelection?) {
            pendingHighlight = highlightInteractor.pendingHighlight(
                for: selection
            )
        }

        private func saveHighlight(
            pending: PendingHighlight,
            color: HighlightColor,
            note: String?
        ) {
            let interactor = highlightInteractor
            Task { @MainActor in
                await interactor.save(
                    pending: pending,
                    color: color,
                    note: note
                )
                pendingHighlight = nil
            }
        }

        private func startNoteFlow(for pending: PendingHighlight) {
            let interactor = highlightInteractor
            Task { @MainActor in
                if let saved = await interactor.startNoteFlow(for: pending) {
                    editingNoteText = ""

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

                activeSheet = nil
            }
        }
    #endif
}

#if canImport(UIKit)

    struct PendingHighlight: Equatable {
        let locator: PDFHighlightLocator
        let text: String
    }
#endif

private actor PDFPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

@MainActor
private func makePDFPreviewViewModel(theme: ReaderTheme = .light)
    -> PDFReaderViewModel
{
    let url =
        AppResourceBundle.bundle.url(forResource: "sample", withExtension: "pdf")
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
