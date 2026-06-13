import Foundation
import RishiCore
import RishiLogging

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

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor] = [:],
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.booksDirURL = rootURL.appendingPathComponent("Books", isDirectory: true)
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.fileManager = fileManager
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
    public func importBook(from sourceURL: URL, ownerId: UserID) async throws -> Book {
        try ensureBooksDirExists()

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw StorageError.unsupportedFormat(ext: ext)
        }

        let bookId = UUID()
        let bookDir = booksDirURL.appendingPathComponent(bookId.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        let destURL = bookDir.appendingPathComponent(filename)

        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw StorageError.copyFailed(underlying: error)
        }

        // Best-effort metadata extraction (never throws). The fields default
        // to "filename-derived title + nil author"; whenever the embedded
        // metadata is present and non-empty it overrides the filename. This
        // is what makes the search bar actually match the user's "Alice in
        // Wonderland" mental model instead of the `1751655…_alice.epub`
        // filename hash.
        var metadata = BookMetadata()
        if let extractor = metadataExtractors[ext] {
            metadata = await extractor.extractMetadata(from: destURL)
        }

        // Best-effort cover extraction (never throws).
        var coverPath: String?
        if let extractor = coverExtractors[ext] {
            if let png = await extractor.extractCover(from: destURL) {
                let coverURL = bookDir.appendingPathComponent("cover.png")
                do {
                    try png.write(to: coverURL, options: .atomic)
                    coverPath = relativePath(of: coverURL)
                } catch {
                    Log.event(
                        "cover.write.failed",
                        level: .info,
                        data: ["book": bookId.uuidString, "error": String(describing: error)]
                    )
                }
            }
        }

        let book = Book(
            id: bookId,
            userId: ownerId,
            title: metadata.title ?? titleFallback(from: filename),
            author: metadata.author,
            formatType: format,
            addedAt: Date(),
            openedAt: nil,
            fileURL: relativePath(of: destURL),
            coverPath: coverPath
        )
        try await bookStore.upsert(book)
        return book
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

    private func ensureBooksDirExists() throws {
        if !fileManager.fileExists(atPath: booksDirURL.path) {
            try fileManager.createDirectory(at: booksDirURL, withIntermediateDirectories: true)
        }
    }

    private func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if target.hasPrefix(root + "/") {
            return String(target.dropFirst(root.count + 1))
        }
        return target
    }

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

    private func titleFallback(from filename: String) -> String {
        let nameOnly = (filename as NSString).deletingPathExtension
        let withSpaces = nameOnly.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces.isEmpty ? "Untitled" : withSpaces
    }
}
