import Foundation
import RishiCore

/// Owns the on-disk layout for imported book files and extracted covers.
///
/// Layout under `rootURL`:
/// ```
/// Books/
///   <bookId>/
///     <originalFilename>.<ext>   // the imported file (copied, not moved)
///     cover.png                  // best-effort cover image (may be absent)
/// ```
///
/// All `Book.fileURL` and `Book.coverPath` values are stored RELATIVE to
/// `rootURL` so the database round-trips across iCloud / device restores
/// where the absolute Documents-directory path changes per install.
public actor BookFileStorage {
    public enum StorageError: Error, Sendable {
        case sourceUnreadable
        case copyFailed(underlying: Error)
        case unsupportedFormat(ext: String)
        case bookNotFound
    }

    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let fileManager: FileManager
    private let coverCache: CoverCache?
    /// Phase 25 Plan 25-11 — fire-and-forget RAG indexing seam. Default
    /// `NoopBookIndexingHook` so existing call sites (tests, sample-book
    /// installers) keep working byte-compatibly. Production AppDependencies
    /// wires a `RishiSearchIndexingHook` from the `RishiSearch` package.
    private let bookIndexingHook: any BookIndexingHook

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor] = [:],
        fileManager: FileManager = .default,
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook()
    ) {
        self.rootURL = rootURL
        self.booksDirURL = rootURL.appendingPathComponent("Books", isDirectory: true)
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.fileManager = fileManager
        self.bookIndexingHook = bookIndexingHook
        // Phase 21: opportunistic disk cache for extracted covers. Lives under
        // `<root>/Caches/book-covers/` so we don't pollute the Books layout.
        // The cache is only useful when we have extractors to delegate to; in
        // test fixtures that pass `coverExtractors: [:]` we leave it nil so
        // the legacy "cover.png-only" path is preserved.
        if coverExtractors.isEmpty {
            self.coverCache = nil
        } else {
            // Pin to `FileManager.default` (documented thread-safe) so the
            // cache can be created from this @MainActor / nonisolated init
            // without tripping Swift 6 strict-concurrency `sending` rules.
            // The init parameter still threads through a custom FileManager
            // for the synchronous in-actor operations (copyItem, etc.).
            self.coverCache = CoverCache(
                cacheDir: rootURL
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("book-covers", isDirectory: true)
            )
        }
    }

    /// Copies `sourceURL` into the library, inserts a `Book` row, best-effort
    /// extracts a cover. Returns the persisted `Book`.
    ///
    /// Plan 34-17 — thin facade over `BookImporter`, which owns the import
    /// orchestration (copy + metadata + cover + upsert + index hook). Kept here
    /// so every existing call site (ImportCoordinator, SampleBookInstaller,
    /// UITestSupport, tests) stays unchanged.
    public func importBook(from sourceURL: URL, ownerId: UserID) async throws -> Book {
        let importer = BookImporter(
            rootURL: rootURL,
            booksDirURL: booksDirURL,
            bookStore: bookStore,
            coverExtractors: coverExtractors,
            metadataExtractors: metadataExtractors,
            bookIndexingHook: bookIndexingHook
        )
        return try await importer.importBook(from: sourceURL, ownerId: ownerId)
    }

    /// Removes the book row and the entire `Books/<bookId>/` directory.
    public func delete(_ book: Book) async throws {
        let bookDir = booksDirURL.appendingPathComponent(book.id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: bookDir.path) {
            try fileManager.removeItem(at: bookDir)
        }
        await coverCache?.clear(book.id)
        try await bookStore.delete(book.id)
    }

    /// Phase 21 perf — nonisolated cache-hit fast path. Skips BOTH the
    /// BookFileStorage actor hop AND the CoverCache actor hop when the
    /// HEIC + mtime sidecar are present and fresh. The library renders N
    /// tiles in parallel via `withTaskGroup`; previously every tile (even
    /// cache HITs) had to queue behind the BookFileStorage actor's single
    /// executor just to compute a relative-to-absolute URL and stat the
    /// sidecar. With this fast path the warm-cache library paint is
    /// effectively zero-cost per tile.
    ///
    /// Returns `nil` on cold cache / stale sidecar / missing coverPath —
    /// caller must fall back to the async `cachedCoverURL(for:)` slow path.
    public nonisolated func cachedCoverURLIfFresh(for book: Book) -> URL? {
        guard let cache = coverCache else { return nil }
        let sourceFileURL: URL
        if let rel = book.coverPath {
            sourceFileURL = rootURL.appendingPathComponent(rel)
        } else {
            // No coverPath — the cache could only exist if a previous
            // extraction wrote it; key off the book file itself for the
            // mtime check (matches the slow-path's sourceFileURL in the
            // legacy-extract branch).
            sourceFileURL = rootURL.appendingPathComponent(book.fileURL)
        }
        return cache.cachedURLIfFresh(for: book.id, sourceFileURL: sourceFileURL)
    }

    /// Returns an absolute URL for a book's cached cover if one was extracted.
    ///
    /// Phase 19 Plan 19-02 (F-P0-02): the `FileManager.fileExists(atPath:)`
    /// syscall is dispatched into a `Task.detached` so it runs off this actor's
    /// executor. Library cover paint fans out N of these calls concurrently
    /// via `LibraryRootView.computeCoverURLs`; keeping the stat syscall on the
    /// actor would re-serialise them on a single thread and defeat the fan-out.
    /// The actor still owns the inputs (`rootURL`, `book.coverPath`, `fileManager`)
    /// so the function remains correct under Swift 6 strict concurrency.
    public func cachedCoverURL(for book: Book) async -> URL? {
        // Phase 21 follow-up — always prefer the downsampled HEIC cache
        // even when `book.coverPath` already points at a full-resolution
        // `cover.png`. Reasoning: AsyncImage decoding a 2000x3000 PNG for
        // every tile on every library paint is the root cause of the
        // "covers take a long time to come in" regression. The cache
        // produces a 600x900 HEIC once, then serves it forever.
        //
        // The cache treats the existing `cover.png` (when present) as the
        // extractor source — that path skips the slow EPUB / PDF re-extract
        // and only pays the cheap one-time downsample. When `coverPath` is
        // nil we fall back to the book-file extractor (legacy lazy path).
        if let cache = coverCache {
            if let rel = book.coverPath {
                let coverFileURL = rootURL.appendingPathComponent(rel)
                // Phase 21 perf — nonisolated cache-hit fast path. The
                // library renders N tiles via `withTaskGroup`; previously
                // every "hit" tile still had to queue behind the
                // CoverCache actor's single executor just to stat the
                // sidecar. The nonisolated helper checks the HEIC + mtime
                // sidecar with `FileManager.default` directly, so all N
                // checks run truly concurrently on the cooperative
                // executor. We ONLY hop into the actor on miss / stale.
                if let hit = cache.cachedURLIfFresh(for: book.id, sourceFileURL: coverFileURL) {
                    return hit
                }
                if await Self.fileExistsOffActor(path: coverFileURL.path) {
                    // Use the on-disk PNG as the extractor source — much
                    // faster than re-opening the EPUB/PDF and avoids the
                    // ZIP / PDFKit decode entirely.
                    let extractor = PassthroughDataExtractor(sourceURL: coverFileURL)
                    if let url = await cache.cachedURL(
                        for: book.id,
                        sourceFileURL: coverFileURL,
                        extractor: extractor
                    ) {
                        return url
                    }
                    // Cache encode failed (e.g. simulator without HEIC) —
                    // fall back to the legacy raw-PNG URL so the tile still
                    // renders something.
                    return coverFileURL
                }
            }

            // No coverPath (or the file is missing) — fall back to the
            // legacy lazy extraction path. This rescues two legitimate
            // cases observed in the field:
            //   1. Books imported before the EPUB extractor was robust
            //      (DB `coverPath` is NULL even though the file is a valid
            //      EPUB).
            //   2. Books whose `cover.png` was deleted out from under us
            //      by an iCloud restore that didn't include the per-book
            //      directory.
            let ext = (book.fileURL as NSString).pathExtension.lowercased()
            guard let extractor = coverExtractors[ext] else { return nil }
            let sourceURL = rootURL.appendingPathComponent(book.fileURL)
            // Phase 21 perf — fast-path the cache HIT for the lazy-extract
            // branch too: a warm cache should never queue behind the
            // CoverCache actor on subsequent paints.
            if let hit = cache.cachedURLIfFresh(for: book.id, sourceFileURL: sourceURL) {
                return hit
            }
            return await cache.cachedURL(
                for: book.id,
                sourceFileURL: sourceURL,
                extractor: extractor
            )
        }

        // No cache configured (test fixtures with `coverExtractors: [:]`).
        // Preserve the legacy "cover.png-only" path.
        if let rel = book.coverPath {
            let url = rootURL.appendingPathComponent(rel)
            if await Self.fileExistsOffActor(path: url.path) {
                return url
            }
        }
        return nil
    }

    /// Phase 19 Plan 19-02 (F-P0-02): dispatch `FileManager.fileExists` into a
    /// detached task so the syscall runs off this actor's executor. Library
    /// cover paint fans out N of these calls concurrently via
    /// `LibraryRootView.computeCoverURLs`; keeping the stat syscall on the
    /// actor would re-serialise them on a single thread and defeat fan-out.
    ///
    /// `nonisolated static` so the closure captures only `path` (a `String`,
    /// trivially `Sendable`), satisfying Swift 6 strict's `sending`-parameter
    /// rule. Uses `FileManager.default` because `FileManager` is not declared
    /// `Sendable` and cannot be transferred to the detached body. The init
    /// parameter still accepts a custom `FileManager` for the in-actor sync
    /// operations (`copyItem`, `createDirectory`, etc.); only the off-actor
    /// existence check pins to the documented-thread-safe singleton.
    private nonisolated static func fileExistsOffActor(path: String) async -> Bool {
        // Phase 20 structured-concurrency audit: `nonisolated async` functions
        // are executed on the generic (cooperative) executor per SE-0338, so
        // the `FileManager.fileExists` syscall already runs off the calling
        // actor without an explicit `Task.detached` hop. The wrapper was
        // redundant; removing it preserves the off-actor guarantee while
        // restoring cancellation propagation from the caller.
        FileManager.default.fileExists(atPath: path)
    }

    /// Returns an absolute URL for the on-disk book file.
    public func absoluteFileURL(for book: Book) -> URL {
        rootURL.appendingPathComponent(book.fileURL)
    }

    // MARK: - Helpers

    /// Phase 21 follow-up — pass-through `CoverExtractor` that just reads
    /// the raw bytes at `sourceURL` and hands them to `CoverCache`. Used to
    /// feed an already-extracted on-disk `cover.png` into the downsampling
    /// cache without paying the EPUB ZIP / PDFKit decode cost again.
    private struct PassthroughDataExtractor: CoverExtractor {
        let sourceURL: URL

        func extractCover(from fileURL: URL) async -> Data? {
            // We ignore `fileURL` and read the URL captured at init time —
            // this lets the cache key off a different mtime source than the
            // extractor payload source. Both URLs are the same `cover.png`
            // in the current call site, so this is purely defensive.
            try? Data(contentsOf: sourceURL)
        }
    }
}
