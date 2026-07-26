import Foundation



/// Phase 21 Plan 21-05 — protocol surface for the PDF page-0 warm cache.
///
/// `PDFThumbnailCache` (Phase 5) satisfies this directly; the wrapper hides
/// the rendered-image return value because the prewarmer only cares about
/// the side effect (page-0 JPG persisted under
/// `<systemCaches>/PDFThumbnails/<bookId>/0.jpg`).
///
/// Decoupling the prewarmer from the concrete `PDFThumbnailCache` lets the
/// unit suite drop in a recording stub without instantiating a real
/// `PDFDocument` from a test fixture.
public protocol PDFPageWarmCache: Sendable {
    /// Trigger the on-disk warm of `pageIndex` for `bookId`'s document. Must
    /// not throw and must not propagate cancellation as an error — the
    /// caller wants silent best-effort behaviour.
    func warmPage(bookId: BookID, documentURL: URL, pageIndex: Int) async
}

extension PDFThumbnailCache: PDFPageWarmCache {
    public func warmPage(bookId: BookID, documentURL: URL, pageIndex: Int) async {
        _ = await thumbnail(bookId: bookId, documentURL: documentURL, pageIndex: pageIndex)
    }
}

/// Phase 21 Plan 21-05 — protocol surface for the EPUB persistent unpack cache.
///
/// `EPUBUnpackedCache` (Plan 21-04) satisfies this directly. Same rationale
/// as `PDFPageWarmCache`: the prewarmer only cares about populating the
/// on-disk warm directory, not the returned URL.
public protocol EPUBWarmCache: Sendable {
    func warmUnpack(bookId: BookID, sourceFileURL: URL) async
}

extension EPUBUnpackedCache: EPUBWarmCache {
    public func warmUnpack(bookId: BookID, sourceFileURL: URL) async {
        _ = await unpackIfNeeded(for: bookId, sourceFileURL: sourceFileURL)
    }
}

/// Phase 21 Plan 21-05 — fires right after a book is imported, warms the
/// format-specific persistent cache so the user's next open is instant
/// regardless of app restart.
///
/// ## Contract
///
/// - **Format dispatch.** `.pdf` warms page 0 via `PDFPageWarmCache`. `.epub`
///   warms the unpacked-directory cache via `EPUBWarmCache`. `.mobi` and
///   `.azw3` are silent no-ops: those formats live in `BookFormat` for the
///   storage schema (Phase 1 decision) but no reader supports them in v1, so
///   pre-warm has nothing to do.
/// - **Cooperative cancellation.** Honoured both before dispatch and after
///   the cache returns; the cache implementations themselves are expected to
///   honour `Task.isCancelled` while suspended.
/// - **Silent failure.** The two cache protocols are non-throwing by design.
///   If the underlying cache fails to populate, the prewarmer still returns
///   normally — the cold-open path remains the fallback in every case.
/// - **Dispatch posture.** Caller is expected to invoke `prewarm(book:fileURL:)`
///   inside `Task.detached(priority: .userInitiated)` from the app composition
///   root so the work runs off the import-flow actor and does not block
///   `LibraryViewModel.refresh()`.
///
/// The dispatcher holds no per-book state; the two cache references are
/// the only fields and they are themselves `Sendable` (each cache owns
/// its own isolation domain). Per Phase 20 canonical-simplicity rule:
/// don't use actor isolation that provides no isolation guarantee — a
/// stateless dispatcher whose only stored fields are Sendable
/// references is a `Sendable` struct, not an actor. Wiring lives in
/// `AppDependencies` (Plan 21-05 Task 2).
public struct BookPrewarmer: Sendable {
    private let pdfCache: any PDFPageWarmCache
    private let epubCache: any EPUBWarmCache

    public init(pdfCache: any PDFPageWarmCache, epubCache: any EPUBWarmCache) {
        self.pdfCache = pdfCache
        self.epubCache = epubCache
    }

    /// Warm the cache for `book` whose on-disk file lives at `fileURL`.
    /// Returns when the underlying cache has either finished its work or
    /// observed cancellation. Never throws; logs a single `book.prewarm.complete`
    /// event on the happy path so the orchestrator can see the warm-up
    /// landing in test runs.
    public func prewarm(book: Book, fileURL: URL) async {
        if Task.isCancelled { return }
        switch book.formatType {
        case .pdf:
            await pdfCache.warmPage(bookId: book.id, documentURL: fileURL, pageIndex: 0)
        case .epub:
            await epubCache.warmUnpack(bookId: book.id, sourceFileURL: fileURL)
        case .mobi, .azw3:
            // No reader supports these in v1 — Phase 1 declared them so the
            // storage schema is forward-compatible with future Kindle-format
            // support. Pre-warm correctly skips and emits no log event so
            // the breadcrumb stream stays signal-only.
            return
        }
        if Task.isCancelled { return }
        Log.event(
            "book.prewarm.complete",
            level: .info,
            data: [
                "bookId": book.id.uuidString,
                "format": book.formatType.rawValue,
            ]
        )
    }
}
