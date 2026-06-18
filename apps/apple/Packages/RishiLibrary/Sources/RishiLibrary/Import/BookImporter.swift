import Foundation
import RishiCore
import RishiLogging

/// Owns the book-import orchestration pipeline: copy the source file into the
/// library, mint a deterministic id, extract metadata + cover, upsert the
/// `Book` row, and fire the RAG indexing hook.
///
/// Extracted from `BookFileStorage` (plan 34-17) so the storage type is left
/// owning only the on-disk layout primitives (copy/delete/path resolution) and
/// the cover-cache read methods. `BookFileStorage.importBook` remains a thin
/// facade that delegates here, so every existing call site (ImportCoordinator,
/// SampleBookInstaller, UITestSupport, tests) is unchanged.
///
/// Layout produced under `rootURL`:
/// ```
/// Books/
///   <bookId>/
///     <originalFilename>.<ext>   // the imported file (copied, not moved)
///     cover.png                  // best-effort cover image (may be absent)
/// ```
///
/// `Book.fileURL` and `Book.coverPath` are stored RELATIVE to `rootURL`.
///
/// A `Sendable` value type driven by the `BookFileStorage` actor's `importBook`
/// facade. All of its stored collaborators are `Sendable` (the extractor / store
/// / index-hook protocols are `Sendable`; `URL` is `Sendable`), so it can be
/// awaited from the actor without tripping Swift 6 strict-concurrency
/// `sending`/data-race rules.
///
/// Synchronous filesystem syscalls pin to `FileManager.default` (documented
/// thread-safe). This matches the existing `CoverCache` precedent and is
/// behaviour-identical: every `BookFileStorage` call site uses the default
/// `FileManager`, so the in-actor copy/createDirectory operations always ran
/// against `.default` already.
struct BookImporter: Sendable {
    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let bookIndexingHook: any BookIndexingHook

    /// Pinned to the documented-thread-safe singleton so the type stays
    /// `Sendable`; see the type doc-comment.
    private var fileManager: FileManager { .default }

    init(
        rootURL: URL,
        booksDirURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor],
        bookIndexingHook: any BookIndexingHook
    ) {
        self.rootURL = rootURL
        self.booksDirURL = booksDirURL
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.bookIndexingHook = bookIndexingHook
    }

    /// Copies `sourceURL` into the library, inserts a `Book` row, best-effort
    /// extracts a cover. Returns the persisted `Book`.
    func importBook(from sourceURL: URL, ownerId: UserID) async throws -> Book {
        try ensureBooksDirExists()

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: ext)
        }

        // Best-effort metadata extraction (never throws). The fields default
        // to "filename-derived title + nil author"; whenever the embedded
        // metadata is present and non-empty it overrides the filename. This
        // is what makes the search bar actually match the user's "Alice in
        // Wonderland" mental model instead of the `1751655…_alice.epub`
        // filename hash. Extracted from `sourceURL` BEFORE the id is minted so
        // the id can be derived from the metadata.
        var metadata = BookMetadata()
        if let extractor = metadataExtractors[ext] {
            metadata = await extractor.extractMetadata(from: sourceURL)
        }

        // Deterministic id from normalized title+author+format so the same
        // book imported on two devices (or under a different filename)
        // collapses to one id and dedupes through the sync upsert. Untitled
        // books fall back to a random UUID so they don't all collapse together.
        let bookId = DeterministicBookID.make(
            title: metadata.title,
            author: metadata.author,
            format: format
        ) ?? UUID()
        let bookDir = booksDirURL.appendingPathComponent(bookId.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        let destURL = bookDir.appendingPathComponent(filename)

        // The id is deterministic, so re-importing the same book locally
        // reuses the same `Books/<id>/` dir and the copy can hit an existing
        // file — make it idempotent.
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw BookFileStorage.StorageError.copyFailed(underlying: error)
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
        // Phase 25 Plan 25-11 — fire RAG indexing AFTER the book is openable
        // (file copied + row upserted). The hook must return quickly (production
        // conformer spawns a `Task.detached`); we await the hook itself but not
        // the indexing work. Failures surface via the per-book index.status.json
        // sidecar, never thrown back through importBook.
        await bookIndexingHook.scheduleIndexing(for: book, fileURL: destURL)
        return book
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

    private func titleFallback(from filename: String) -> String {
        let nameOnly = (filename as NSString).deletingPathExtension
        let withSpaces = nameOnly.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces.isEmpty ? "Untitled" : withSpaces
    }
}
