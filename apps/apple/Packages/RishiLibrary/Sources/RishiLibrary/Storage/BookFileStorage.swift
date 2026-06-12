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
    private let fileManager: FileManager

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.booksDirURL = rootURL.appendingPathComponent("Books", isDirectory: true)
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.fileManager = fileManager
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
            title: titleFallback(from: filename),
            author: nil,
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
        guard let rel = book.coverPath else { return nil }
        let url = rootURL.appendingPathComponent(rel)
        let exists = await Self.fileExistsOffActor(path: url.path)
        return exists ? url : nil
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
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
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

    private func titleFallback(from filename: String) -> String {
        let nameOnly = (filename as NSString).deletingPathExtension
        let withSpaces = nameOnly.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces.isEmpty ? "Untitled" : withSpaces
    }
}
