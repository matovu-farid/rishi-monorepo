import Foundation


public struct BookFileStorage:Sendable {
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
    private let isTombstoned: (@Sendable (BookID) async -> Bool)?
   
    private var fileManager: FileManager { .default }
    private let coverCache: CoverCache?

    private let bookIndexingHook: any BookIndexingHook

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor] = [:],
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook(),
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil
    ) {
        self.rootURL = rootURL
        self.booksDirURL = rootURL.appendingPathComponent(
            "Books",
            isDirectory: true
        )
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.bookIndexingHook = bookIndexingHook
        self.isTombstoned = isTombstoned

        if coverExtractors.isEmpty {
            self.coverCache = nil
        } else {

            self.coverCache = CoverCache(
                cacheDir:
                    rootURL
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("book-covers", isDirectory: true)
            )
        }
    }

    public func importBook(from sourceURL: URL, ownerId: UserID) async throws
        -> Book
    {
        let importer = BookImporter(
            rootURL: rootURL,
            booksDirURL: booksDirURL,
            bookStore: bookStore,
            coverExtractors: coverExtractors,
            metadataExtractors: metadataExtractors,
            bookIndexingHook: bookIndexingHook,
            isTombstoned: isTombstoned
        )
        return try await importer.importBook(from: sourceURL, ownerId: ownerId)
    }
   

    public func delete(_ book: Book) async throws {
        try await deleteMaterial(for: book)
        try await bookStore.delete(book.id)
    }

    /// Removes the local file and cover cache while leaving the metadata row
    /// untouched. Inbound sync uses this before conditionally deleting the
    /// row so a failed acknowledgement can retry safely.
    public func deleteMaterial(for book: Book) async throws {
        try await deleteMaterial(forBookID: book.id)
    }

    /// Removes material by identity even when the local Book row is already
    /// gone. Inbound tombstones use this form so a partial delete remains
    /// repairable on a later retry.
    public func deleteMaterial(forBookID bookID: BookID) async throws {
        let bookDir = booksDirURL.appendingPathComponent(
            bookID.uuidString,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: bookDir.path) {
            try fileManager.removeItem(at: bookDir)
        }
        await coverCache?.clear(bookID)
    }

    /// Removes all local book material, including extracted covers and search
    /// sidecars. The Rishi app's local store belongs to the signed-in account.
    public func purgeAll() throws {
        for url in [
            booksDirURL,
            rootURL.appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("book-covers", isDirectory: true),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        // Drag/drop imports use a namespaced temporary copy while the system
        // document picker is active. Remove only Rishi-owned temporary files;
        // never sweep the platform temporary directory wholesale.
        let temporaryDirectory = fileManager.temporaryDirectory
        for url in try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) where url.lastPathComponent.hasPrefix("RishiDrop-") {
            try? fileManager.removeItem(at: url)
        }
    }

    public nonisolated func cachedCoverURLIfFresh(for book: Book) -> URL? {
        guard let cache = coverCache else { return nil }
        let sourceFileURL: URL
        if let rel = book.coverPath {
            sourceFileURL = rootURL.appendingPathComponent(rel)
        } else {

            sourceFileURL = rootURL.appendingPathComponent(book.fileURL)
        }
        return cache.cachedURLIfFresh(
            for: book.id,
            sourceFileURL: sourceFileURL
        )
    }

    public func cachedCoverURL(for book: Book) async -> URL? {

        if let cache = coverCache {
            if let rel = book.coverPath {
                let coverFileURL = rootURL.appendingPathComponent(rel)

                if let hit = cache.cachedURLIfFresh(
                    for: book.id,
                    sourceFileURL: coverFileURL
                ) {
                    return hit
                }
                if await Self.fileExistsOffActor(path: coverFileURL.path) {

                    let extractor = PassthroughDataExtractor(
                        sourceURL: coverFileURL
                    )
                    if let url = await cache.cachedURL(
                        for: book.id,
                        sourceFileURL: coverFileURL,
                        extractor: extractor
                    ) {
                        return url
                    }

                    return coverFileURL
                }
            }

            let ext = (book.fileURL as NSString).pathExtension.lowercased()
            guard let extractor = coverExtractors[ext] else { return nil }
            let sourceURL = rootURL.appendingPathComponent(book.fileURL)

            if let hit = cache.cachedURLIfFresh(
                for: book.id,
                sourceFileURL: sourceURL
            ) {
                return hit
            }
            return await cache.cachedURL(
                for: book.id,
                sourceFileURL: sourceURL,
                extractor: extractor
            )
        }

        if let rel = book.coverPath {
            let url = rootURL.appendingPathComponent(rel)
            if await Self.fileExistsOffActor(path: url.path) {
                return url
            }
        }
        return nil
    }

    private nonisolated static func fileExistsOffActor(path: String) async
        -> Bool
    {

        FileManager.default.fileExists(atPath: path)
    }

    public func absoluteFileURL(for book: Book) -> URL {
        rootURL.appendingPathComponent(book.fileURL)
    }

    /// Materializes a book downloaded from the sync service into the same
    /// platform-local layout used by imports. The returned value points at the
    /// local relative path; callers should persist it only after this method
    /// succeeds.
    public func materializeDownloadedBook(_ book: Book, data: Data) throws -> Book {
        let directory = booksDirURL.appendingPathComponent(book.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(book.id.uuidString).\(book.formatType.rawValue)")
        try data.write(to: fileURL, options: .atomic)
        let relative = "Books/\(book.id.uuidString)/\(fileURL.lastPathComponent)"
        return Book(
            id: book.id,
            userId: book.userId,
            title: book.title,
            author: book.author,
            formatType: book.formatType,
            addedAt: book.addedAt,
            openedAt: book.openedAt,
            fileURL: relative,
            coverPath: book.coverPath,
            positionId: book.positionId,
            conversationId: book.conversationId,
            chapterIndexContentVersion: book.chapterIndexContentVersion
        )
    }

    private struct PassthroughDataExtractor: CoverExtractor {
        let sourceURL: URL

        func extractCover(from fileURL: URL) async -> Data? {

            try? Data(contentsOf: sourceURL)
        }
    }
}
