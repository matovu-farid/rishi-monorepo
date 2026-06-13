import Foundation
@preconcurrency import PDFKit
import Observation
import RishiCore
import RishiLogging

/// Encodes/decodes the per-page locator stored in `Position.locator` for PDFs.
///
/// Wire format: `"pdf-v1:page:N"` where `N` is the zero-based page index.
/// The `pdf-v1` prefix lets Phase 7 sync identify the schema; a future
/// `pdf-v2` decoder will fall back to `pdf-v1` for backward compat.
public enum PDFPositionEncoder {
    public static let format = "pdf-v1"

    public static func encode(page: Int) -> String { "\(format):page:\(page)" }

    public static func decode(_ locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 3,
              parts[0] == Substring(format),
              parts[1] == "page",
              let page = Int(parts[2]) else { return nil }
        return page
    }
}

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
    public private(set) var outline: [PDFOutlineNode] = []

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

        if let last = try? await positionStore.position(for: book.id),
           let restored = PDFPositionEncoder.decode(last.locator),
           restored >= 0, restored < totalPages {
            self.pageIndex = restored
        }
        self.loadingState = .loaded
    }

    /// Called by the PDFView delegate (`pdfViewPageChanged`) on every page
    /// turn. Updates the in-memory `pageIndex` immediately so the indicator
    /// reflects state, and debounces the position write.
    public func didChangePage(toIndex newIndex: Int) {
        guard newIndex != pageIndex, newIndex >= 0, newIndex < totalPages else { return }
        pageIndex = newIndex
        schedulePositionWrite(pageIndex: newIndex)
    }

    /// Public seek API used by the TOC sheet (plan 05-07) and bottom slider.
    public func seek(toPage newIndex: Int) {
        guard let doc = document, newIndex >= 0, newIndex < doc.pageCount else { return }
        pageIndex = newIndex
        schedulePositionWrite(pageIndex: newIndex)
    }

    /// Flushes any pending debounced write immediately. Call on view dismiss.
    public func flush() async {
        pendingPositionTask?.cancel()
        pendingPositionTask = nil
        await writePosition(pageIndex: pageIndex)
    }

    // MARK: - Debounce

    private func schedulePositionWrite(pageIndex: Int) {
        pendingPositionTask?.cancel()
        let seconds = debounceSeconds
        // KEEP: VM is @Observable (not @MainActor) per the class doc-comment;
        // debounce body sleeps then awaits positionStore.upsert (actor). No
        // main-bound work.
        pendingPositionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.writePosition(pageIndex: pageIndex)
        }
    }

    private func writePosition(pageIndex: Int) async {
        let percent = totalPages > 0 ? Double(pageIndex) / Double(totalPages) : 0
        let position = Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(page: pageIndex),
            percentComplete: percent,
            updatedAt: Date()
        )
        do {
            try await positionStore.upsert(position)
        } catch {
            Log.reader.error("Failed to persist PDF position page=\(pageIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
