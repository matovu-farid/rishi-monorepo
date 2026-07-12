import Foundation
@preconcurrency import PDFKit
import Observation
import RishiCore
import RishiLogging

/// Owns the page state, position-debounce task, outline, and theme for one
/// open PDF.
///
/// Marked `@Observable` for SwiftUI bindings. NOT `@MainActor` because the
/// PDFKit `PDFViewPageChanged` notification is delivered on whatever queue
/// `PDFView` was hosted on (typically main, but the contract is unspecified).
/// State mutations are localized to single methods; the debounce uses a
/// detached `Task` keyed off the latest call so coalescing happens via
/// `cancel()` on the previous pending write.
///
/// `userId` is `internal` (not `private`) so the highlight extension landing
/// in plan 05-06 can pass it through to `HighlightStore.upsert(_:)`.
/// @unchecked Sendable justified: holds the non-Sendable PDFKit
/// `PDFDocument?` plus several `var` properties driving the `@Observable`
/// surface. Mutations are scoped to single methods invoked from main; the
/// reader screen treats this VM as MainActor-pinned in practice.
@Observable
public final class PDFReaderViewModel: @unchecked Sendable {

    public let book: Book
    public private(set) var document: PDFDocument?
    public private(set) var totalPages: Int = 0
    public private(set) var pageIndex: Int = 0
    public private(set) var readAloudStartParagraphIndex: Int = 0
    public private(set) var outline: [PDFOutlineNode] = []
    public var activeSheet: ReaderSheet?
    
    public var bookmarkToggle: PDFBookmarkToggleModel?
    
    


    /// Phase 21 Plan 21-03 — observable cold-open loading state.
    /// `PDFReaderScreen` overlays a native SwiftUI `ProgressView` while
    /// this is `.loading`, surfaces an error view on `.failed`, and
    /// renders the page content normally on `.loaded`. Starts `.idle`
    /// until ``load()`` runs.
    public private(set) var loadingState: ReaderLoadingState = .idle

    public var theme: ReaderTheme = .default

    // MARK: - Phase 18 Plan 18-02 — F-P1-01 SwiftUI native haptics

    /// Monotonically-increasing trigger value observed by the reader
    /// screen's `.sensoryFeedback(.impact(weight: .light), trigger:)`
    /// modifier. SwiftUI fires the haptic whenever this value changes;
    /// callers should invoke ``advancePage()`` on every committed page
    /// turn rather than mutating the field directly. Use
    /// `&+` overflow wrapping so a long reading session can never
    /// trap on `Int.max` — wrap-around is still a change.
    public private(set) var currentPageIndex: Int = 0

    /// Monotonically-increasing trigger value observed by the reader
    /// screen's `.sensoryFeedback(.warning, trigger:)` modifier.
    /// Incremented whenever the user hits a boundary (page-before-first
    /// or page-after-last). Same overflow-wrapping semantics as
    /// ``currentPageIndex``.
    public private(set) var lastBoundaryHitTick: Int = 0

    /// Bumps ``currentPageIndex`` by 1. SwiftUI's
    /// `.sensoryFeedback(_:trigger:)` observes the change and fires a
    /// light impact haptic on the reader screen.
    public func advancePage() {
        currentPageIndex &+= 1
    }

    /// Bumps ``lastBoundaryHitTick`` by 1. SwiftUI's
    /// `.sensoryFeedback(_:trigger:)` observes the change and fires a
    /// warning notification haptic on the reader screen.
    public func hitBoundary() {
        lastBoundaryHitTick &+= 1
    }

    internal let userId: UserID

    private let positionStore: any PositionStore
    private let documentURL: URL
    private let debounceSeconds: Double
    private let documentLoader: @Sendable (URL) async -> PDFDocument?
    private var pendingPositionTask: Task<Void, Never>?
    private var currentReadAloudParagraphText: String?

    public init(
        book: Book,
        userId: UserID,
        documentURL: URL,
        positionStore: any PositionStore,
        debounceSeconds: Double = 1.0,
        documentLoader: (@Sendable (URL) async -> PDFDocument?)? = nil
    ) {
        self.book = book
        self.userId = userId
        self.documentURL = documentURL
        self.positionStore = positionStore
        self.debounceSeconds = debounceSeconds
        self.documentLoader = documentLoader ?? { url in PDFDocument(url: url) }
    }

    // MARK: - Lifecycle

    /// Loads the document, extracts the outline, restores the last position.
    /// Call once when the view appears.
    ///
    /// The synchronous `PDFDocument(url:)` parse can take multiple seconds
    /// on large books, so the call is dispatched to
    /// `Task.detached(priority: .userInitiated)` and the result is awaited
    /// back via `.value`. `Task.detached`'s `.value` is a `sending` return,
    /// so the detached task's result can cross back into this viewmodel's
    /// isolation. PDFKit's `PDFDocument` is not formally `Sendable`, but
    /// the module is imported `@preconcurrency` at the top of this file
    /// because PDFDocument is safe to construct on one thread and read
    /// from another (Apple's own off-main parse pattern depends on it).
    /// State assignment after the await still happens on this viewmodel's
    /// executor — callers typically dispatch `load()` from a `@MainActor`
    /// `.task` modifier, so post-load mutations remain observable from
    /// SwiftUI.
    public func load() async {
        // Phase 21 Plan 21-03 — flip to .loading BEFORE the detached
        // parse so the cold-open overlay binds immediately. Lands on
        // the caller's executor (typically MainActor via SwiftUI's
        // `.task`) so SwiftUI sees the transition on the same tick the
        // overlay first renders.
        self.loadingState = .loading
        let loader = self.documentLoader
        let url = self.documentURL
        let loaded: PDFDocument? = await Task.detached(priority: .userInitiated) {
            await loader(url)
        }.value
        guard let doc = loaded else {
            Log.reader.error("Failed to open PDFDocument at \(self.documentURL.path, privacy: .public)")
            self.loadingState = .failed(reason: "Failed to open PDF document")
            return
        }
        self.document = doc
        self.totalPages = doc.pageCount
        self.outline = PDFOutlineExtractor.extract(from: doc)
        resetReadAloudParagraph()

        // Under RISHI_UITEST always open at page 1 (skip position restore) so
        // read-aloud page-boundary UITests start deterministically with a real
        // boundary ahead — the persisted position otherwise bleeds between test
        // methods. DEBUG + env-gated, so never affects a release build.
        #if DEBUG
        let uitestFreshStart = ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
        #else
        let uitestFreshStart = false
        #endif
        if !uitestFreshStart,
           let last = try? await positionStore.position(for: book.id),
           let restored = PDFPositionEncoder.decodePosition(last.locator),
           restored.pageIndex >= 0, restored.pageIndex < totalPages {
            self.pageIndex = restored.pageIndex

            guard let paragraphIndex = restored.paragraphIndex,
                  let paragraphHash = restored.paragraphHash else {
                self.loadingState = .loaded
                return
            }

            let paragraphs = readAloudCursor.paragraphs(atPage: restored.pageIndex)
            guard paragraphIndex >= 0,
                  paragraphIndex < paragraphs.count,
                  PDFPositionEncoder.paragraphHash(paragraphs[paragraphIndex]) == paragraphHash else {
                resetReadAloudParagraph()
                self.loadingState = .loaded
                return
            }

            self.readAloudStartParagraphIndex = paragraphIndex
            self.currentReadAloudParagraphText = paragraphs[paragraphIndex]
        }
        self.loadingState = .loaded
    }

    /// Called by the PDFView delegate (`pdfViewPageChanged`) on every page
    /// turn. Updates the in-memory `pageIndex` immediately so the indicator
    /// reflects state, and debounces the position write.
    public func didChangePage(toIndex newIndex: Int) {
        guard newIndex != pageIndex, newIndex >= 0, newIndex < totalPages else { return }
        pageIndex = newIndex
        readAloudStartParagraphIndex = 0
        resetReadAloudParagraph()
        schedulePositionWrite(pageIndex: newIndex)
    }

    /// Public seek API used by the TOC sheet (plan 05-07) and bottom slider.
    public func seek(toPage newIndex: Int) {
        guard let doc = document, newIndex >= 0, newIndex < doc.pageCount else { return }
        pageIndex = newIndex
        resetReadAloudParagraph()
        schedulePositionWrite(pageIndex: newIndex)
    }

    /// Called by the read-aloud controller whenever the active passage changes.
    /// The paragraph index is page-local; invalid indexes are ignored so a
    /// stale callback cannot persist a locator that cannot be resumed.
    public func didChangeReadAloudPassage(to paragraphIndex: Int, text: String) {
        let paragraphs = readAloudCursor.paragraphs(atPage: pageIndex)
        guard paragraphIndex >= 0, paragraphIndex < paragraphs.count else { return }

        let canonicalText = paragraphs[paragraphIndex]
        readAloudStartParagraphIndex = paragraphIndex
        currentReadAloudParagraphText = canonicalText
        schedulePositionWrite(
            pageIndex: pageIndex,
            paragraphIndex: paragraphIndex,
            paragraphText: canonicalText
        )
    }

    // MARK: - Read-aloud continuation

    /// Paragraphs for the NEXT page with selectable text after the page
    /// read-aloud is currently narrating, so playback continues across a page
    /// boundary instead of halting at the last paragraph of the current page.
    ///
    /// Mirrors the EPUB reader's chapter-boundary continuation
    /// (``ReaderViewModel/paragraphsForFollowingResource()``): it advances
    /// past any intervening pages that produce zero paragraphs (blank pages,
    /// image-only separators) and moves the live ``pageIndex`` onto the new
    /// page via ``seek(toPage:)`` so the visible page — and the inline
    /// read-aloud highlight — follow narration. Returns `[]` at the end of the
    /// document (no further non-empty page), which the read-aloud bridge
    /// treats as "stop".
    ///
    /// ``pageIndex`` doubles as the narration cursor: each cross seeks the live
    /// page onto the page being narrated, so the next exhaustion advances from
    /// there. The page-turn mutation runs on the MainActor because ``pageIndex``
    /// drives the @Observable SwiftUI surface and must not be written from a
    /// background thread.
    ///
    /// The page-scan itself is delegated to ``PDFReadAloudCursor``; this method
    /// owns only the explicit position application (the `seek`) so the live-page
    /// mutation is visible here rather than hidden in the scan.
    public func paragraphsForFollowingPage() async -> [String] {
        let current = await MainActor.run { self.pageIndex }
        guard let result = readAloudCursor.following(currentPage: current) else { return [] }
        await MainActor.run { self.seek(toPage: result.pageIndex) }
        return result.paragraphs
    }

    /// Paragraphs for the PREVIOUS page with selectable text before the page
    /// read-aloud is currently narrating, so pressing Previous on the first
    /// paragraph of a page continues backward across the page boundary instead
    /// of being a no-op. The backward mirror of ``paragraphsForFollowingPage()``:
    /// it steps back past any intervening pages that produce zero paragraphs
    /// (blank pages, image-only separators) and moves the live ``pageIndex`` onto
    /// the new page via ``seek(toPage:)`` so the visible page — and the inline
    /// read-aloud highlight — follow narration. Returns `[]` at the start of the
    /// document (no earlier non-empty page), which the read-aloud bridge treats
    /// as "stay put".
    public func paragraphsForPrecedingPage() async -> [String] {
        let current = await MainActor.run { self.pageIndex }
        guard let result = readAloudCursor.preceding(currentPage: current) else { return [] }
        await MainActor.run { self.seek(toPage: result.pageIndex) }
        return result.paragraphs
    }

    /// Read-aloud page-continuation collaborator built over the current
    /// document. Rebuilt per access so it always reflects the latest loaded
    /// `document` (the cursor is a cheap value-like wrapper holding only the
    /// document reference and no mutable state).
    private var readAloudCursor: PDFReadAloudCursor {
        PDFReadAloudCursor(document: document)
    }

    /// Flushes any pending debounced write immediately. Call on view dismiss.
    public func flush() async {
        let pendingTask = pendingPositionTask
        pendingPositionTask = nil
        pendingTask?.cancel()
        await pendingTask?.value
        await writePosition(
            pageIndex: pageIndex,
            paragraphIndex: currentReadAloudParagraphText == nil ? nil : readAloudStartParagraphIndex,
            paragraphText: currentReadAloudParagraphText
        )
    }

    // MARK: - Voice context

    /// Flat chapter titles for the voice model's outline. Derived from the
    /// PDF Table-of-Contents via pre-order traversal; empty when the document
    /// has no embedded outline.
    public var voiceChapters: [String] {
        outline.flatMap { $0.flattened() }.map(\.label)
    }

    /// Best-effort text of the current page, extracted synchronously from the
    /// already-loaded `PDFDocument`. `nil` when the document isn't loaded yet
    /// or the page has no selectable text (image-only scans). PDFKit's
    /// per-page text extraction is cheap relative to the document parse, so
    /// this is safe to call from the synchronous toolbar voice action.
    public var currentPageText: String? {
        let paragraphs = readAloudCursor.paragraphs(atPage: pageIndex)
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Build the live reading context handed to the voice session. Title +
    /// author always come from `book`; `currentPage` is the 1-based live page;
    /// `chapters` + `pageText` are best-effort from the loaded document.
    public func voiceContext() -> ReaderVoiceContext {
        ReaderVoiceContext(
            title: book.title,
            author: book.author,
            chapters: voiceChapters,
            currentPage: pageIndex + 1,
            pageText: currentPageText,
            // The PDF reader has no sub-page "active paragraph" cursor outside
            // read-aloud; leave nil — page text already grounds the model.
            activeParagraphText: nil
        )
    }

    // MARK: - Debounce

    private func schedulePositionWrite(
        pageIndex: Int,
        paragraphIndex: Int? = nil,
        paragraphText: String? = nil
    ) {
        pendingPositionTask?.cancel()
        let seconds = debounceSeconds
        // KEEP: VM is @Observable (not @MainActor) per the class doc-comment;
        // debounce body sleeps then awaits positionStore.upsert (actor). No
        // main-bound work.
        pendingPositionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.writePosition(
                pageIndex: pageIndex,
                paragraphIndex: paragraphIndex,
                paragraphText: paragraphText
            )
        }
    }

    private func writePosition(
        pageIndex: Int,
        paragraphIndex: Int? = nil,
        paragraphText: String? = nil
    ) async {
        let percent = totalPages > 0 ? Double(pageIndex) / Double(totalPages) : 0
        let locator: String
        if let paragraphIndex, let paragraphText {
            locator = PDFPositionEncoder.encode(
                page: pageIndex,
                paragraph: paragraphIndex,
                text: paragraphText
            )
        } else {
            locator = PDFPositionEncoder.encode(page: pageIndex)
        }
        let position = Position(
            bookId: book.id,
            locator: locator,
            percentComplete: percent,
            updatedAt: Date()
        )
        do {
            try await positionStore.upsert(position)
        } catch {
            Log.reader.error("Failed to persist PDF position page=\(pageIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetReadAloudParagraph() {
        readAloudStartParagraphIndex = 0
        currentReadAloudParagraphText = nil
    }
}
