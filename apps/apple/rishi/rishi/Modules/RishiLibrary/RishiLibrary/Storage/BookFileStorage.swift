import Foundation

public struct VerifiedManagedFile: Sendable, Equatable {
    public let fingerprint: BookFileFingerprint
    public let fingerprintPersisted: Bool

    public init(fingerprint: BookFileFingerprint, fingerprintPersisted: Bool) {
        self.fingerprint = fingerprint
        self.fingerprintPersisted = fingerprintPersisted
    }
}

public struct BookFileStorage:Sendable {
    public enum StorageError: Error, Sendable {
        case sourceUnreadable
        case copyFailed(underlying: Error)
        case unsupportedFormat(ext: String)
        case bookNotFound
        case bookOwnerMismatch
        case staleDeletionCleanup
    }

    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let isTombstoned: (@Sendable (BookID) async -> Bool)?
    private let fingerprintPersistence: (any BookImportPersistence)?
    private let fingerprintAccountGeneration: @Sendable () async -> UInt64?
    private let materializationCoordinator: BookMaterializationCoordinator?
    private let importInstrumentation: BookImportInstrumentation
   
    private var fileManager: FileManager { .default }
    private let coverCache: CoverCache?

    private let bookIndexingHook: any BookIndexingHook

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor] = [:],
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook(),
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil,
        fingerprintPersistence: (any BookImportPersistence)? = nil,
        fingerprintAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        materializationCoordinator: BookMaterializationCoordinator? = nil,
        importInstrumentation: BookImportInstrumentation = .shared
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
        self.fingerprintPersistence = fingerprintPersistence
        self.fingerprintAccountGeneration = fingerprintAccountGeneration
        self.materializationCoordinator = materializationCoordinator
        self.importInstrumentation = importInstrumentation

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

    public func importBook(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String? = nil
    ) async throws -> Book
    {
        try await importBook(from: sourceURL, ownerId: ownerId, expectedContentHash: expectedContentHash, accountGeneration: nil)
    }

    public func importBook(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String?,
        accountGeneration: UInt64
    ) async throws -> Book {
        try await importBook(from: sourceURL, ownerId: ownerId, expectedContentHash: expectedContentHash, accountGeneration: Optional(accountGeneration))
    }

    /// Persists a normal Book and its readable source lease before returning,
    /// then lets managed-file materialization continue in the background.
    /// When the persistence/coordinator dependencies are unavailable, the
    /// importer preserves the established managed-on-return behavior.
    public func registerSourceReadable(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64
    ) async throws -> SourceReadableBookRegistration {
        let importer = makeImporter(accountGeneration: accountGeneration)
        return try await importer.registerSourceReadable(
            from: sourceURL,
            ownerId: ownerId,
            accountGeneration: accountGeneration
        )
    }

    /// Provider-owned URLs are copied into an Imports/<attempt> directory
    /// before registration returns, so the provider may remove its temporary
    /// representation immediately afterward.
    public func registerOwnedSourceReadable(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64
    ) async throws -> SourceReadableBookRegistration {
        let importer = makeImporter(accountGeneration: accountGeneration)
        return try await importer.registerOwnedSourceReadable(
            from: sourceURL,
            ownerId: ownerId,
            accountGeneration: accountGeneration
        )
    }

    public func validateSourceReadableRegistration(
        _ registration: SourceReadableBookRegistration,
        ownerId: UserID,
        accountGeneration: UInt64
    ) async -> Bool {
        let book = registration.book
        guard book.userId == ownerId,
              let canonical = try? await bookStore.book(book.id),
              canonical.userId == ownerId,
              canonical.fileURL == book.fileURL,
              await isTombstoned?(book.id) != true else { return false }
        if let currentGeneration = await fingerprintAccountGeneration(), currentGeneration != accountGeneration {
            return false
        }
        if let token = registration.token {
            guard token.ownerID == ownerId,
                  token.accountGeneration == accountGeneration,
                  token.bookID == book.id,
                  let job = try? await fingerprintPersistence?.pendingMaterialization(bookID: book.id, ownerID: ownerId),
                  job.token == token,
                  job.phase != .cancelled,
                  job.phase != .failed,
                  let materializationCoordinator,
                  await materializationCoordinator.isReadableSourceAvailable(for: canonical) else { return false }
            return true
        }
        let managedURL = rootURL.appendingPathComponent(canonical.fileURL).standardizedFileURL
        guard managedURL.path.hasPrefix(booksDirURL.standardizedFileURL.path + "/"),
              fileManager.fileExists(atPath: managedURL.path) else { return false }
        if let materializationCoordinator {
            return await materializationCoordinator.isReadableSourceAvailable(for: canonical)
        }
        return true
    }

    private func makeImporter(accountGeneration: UInt64?) -> BookImporter {
        BookImporter(
            rootURL: rootURL,
            booksDirURL: booksDirURL,
            bookStore: bookStore,
            coverExtractors: coverExtractors,
            metadataExtractors: metadataExtractors,
            bookIndexingHook: bookIndexingHook,
            isTombstoned: isTombstoned,
            fingerprintPersistence: fingerprintPersistence,
            fingerprintAccountGeneration: fingerprintAccountGeneration,
            materializationCoordinator: materializationCoordinator,
            capturedAccountGeneration: accountGeneration,
            importInstrumentation: importInstrumentation
        )
    }

    private func importBook(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String?,
        accountGeneration: UInt64?
    ) async throws -> Book {
        let importer = makeImporter(accountGeneration: accountGeneration)
        return try await importer.importBook(
            from: sourceURL,
            ownerId: ownerId,
            expectedContentHash: expectedContentHash
        )
    }
   

    public func delete(_ book: Book) async throws {
        try await deleteMaterial(for: book)
        try await bookStore.delete(book.id)
        NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
    }

    /// Removes the local file and cover cache while leaving the metadata row
    /// untouched. Inbound sync uses this before conditionally deleting the
    /// row so a failed acknowledgement can retry safely.
    public func deleteMaterial(for book: Book) async throws {
        try await removeManagedMaterial(forBookID: book.id)
        try await removePendingStaging(for: book)
    }

    /// Removes material by identity even when the local Book row is already
    /// gone. Inbound tombstones use this form so a partial delete remains
    /// repairable on a later retry.
    public func deleteMaterial(forBookID bookID: BookID) async throws {
        let book = try? await bookStore.book(bookID)
        try await removeManagedMaterial(forBookID: bookID)
        if let book { try await removePendingStaging(for: book) }
    }

    /// Captures the app-owned material cleanup while the canonical Book row
    /// still supplies its owner. The returned action removes bytes only when
    /// the caller's conditional row deletion has succeeded. It remains
    /// repeatable after the row is gone because the owner and validated
    /// attempt path are captured in the closure.
    public func prepareDeletionCleanup(
        bookID: BookID,
        ownerID: UserID
    ) async throws -> @Sendable () async throws -> Void {
        if let book = try await bookStore.book(bookID), book.userId != ownerID {
            throw StorageError.bookOwnerMismatch
        }

        let pending: PendingBookMaterialization?
        if let fingerprintPersistence {
            pending = try await fingerprintPersistence.pendingMaterializationForDeletionCleanup(bookID: bookID, ownerID: ownerID)
        } else {
            pending = nil
        }

        let stagingDirectory: URL?
        if let pending {
            guard pending.token.bookID == bookID,
                  pending.token.ownerID == ownerID,
                  pending.stagingRelativePath == "Imports/\(pending.token.attemptID.uuidString)/content.partial" else {
                throw StorageError.sourceUnreadable
            }
            let importsURL = rootURL.appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
            let attemptURL = importsURL.appendingPathComponent(pending.token.attemptID.uuidString, isDirectory: true).standardizedFileURL
            guard attemptURL.deletingLastPathComponent() == importsURL else {
                throw StorageError.sourceUnreadable
            }
            stagingDirectory = attemptURL
        } else {
            stagingDirectory = nil
        }

        return { [self] in
            try await removeManagedMaterial(forBookID: bookID)
            if let stagingDirectory, fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
            if let pending, let fingerprintPersistence {
                guard try await fingerprintPersistence.deletePendingMaterializationForDeletionCleanup(
                    bookID: bookID,
                    ownerID: ownerID,
                    expectedToken: pending.token
                ) else { throw StorageError.staleDeletionCleanup }
            }
        }
    }

    private func removeManagedMaterial(forBookID bookID: BookID) async throws {
        let bookDir = booksDirURL.appendingPathComponent(
            bookID.uuidString,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: bookDir.path) {
            try fileManager.removeItem(at: bookDir)
        }
        await coverCache?.clear(bookID)
    }

    /// Removes only the attempt-owned staging directory recorded for this
    /// book. Lifecycle retirement must have drained the writer before this is
    /// called; the exact path check prevents persistence data from expanding
    /// deletion beyond Rishi's `Imports/<attempt UUID>` namespace.
    private func removePendingStaging(for book: Book) async throws {
        guard let fingerprintPersistence,
              let pending = try await fingerprintPersistence.pendingMaterialization(
                bookID: book.id,
                ownerID: book.userId
              ),
              pending.token.bookID == book.id,
              pending.token.ownerID == book.userId,
              pending.stagingRelativePath == "Imports/\(pending.token.attemptID.uuidString)/content.partial"
        else { return }

        let importsURL = rootURL.appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
        let attemptURL = importsURL.appendingPathComponent(pending.token.attemptID.uuidString, isDirectory: true).standardizedFileURL
        guard attemptURL.deletingLastPathComponent() == importsURL,
              fileManager.fileExists(atPath: attemptURL.path) else { return }
        try fileManager.removeItem(at: attemptURL)
    }

    /// Removes all local book material, including extracted covers and search
    /// sidecars. The Rishi app's local store belongs to the signed-in account.
    public func purgeAll() throws {
        for url in [
            booksDirURL,
            // This directory contains only attempt-scoped staging files
            // created by BookImporter, never source documents or OS temp.
            rootURL.appendingPathComponent("Imports", isDirectory: true),
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

    /// Verifies downloaded or newly copied managed bytes before recording a
    /// local fingerprint. Remote hash/size values are hints until this succeeds.
    @discardableResult
    public func cacheVerifiedManagedFile(
        for book: Book,
        expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil
    ) async -> VerifiedManagedFile? {
        let service = BookFingerprintService(
            rootURL: rootURL,
            bookStore: bookStore,
            persistence: fingerprintPersistence,
            isTombstoned: isTombstoned
        )
        return await service.verifyAndCacheManagedFile(
            for: book,
            expectedSHA256: expectedSHA256,
            expectedByteCount: expectedByteCount
        )
    }

    /// Commits a fingerprint captured by a verified download after its Book
    /// row has been registered. The persistence CAS rechecks ownership, path,
    /// current authorization, and the observed file version.
    @discardableResult
    public func persistVerifiedFingerprint(_ fingerprint: BookFileFingerprint, for book: Book) async -> Bool {
        guard fingerprintPersistence != nil,
              fingerprint.bookID == book.id,
              fingerprint.ownerID == book.userId,
              await isTombstoned?(book.id) != true,
              let persistence = fingerprintPersistence else { return false }
        return (try? await persistence.cacheManagedFingerprint(
            fingerprint,
            expectedRelativePath: book.fileURL,
            expectedVersion: fingerprint.version
        )) == true
    }

    private struct PassthroughDataExtractor: CoverExtractor {
        let sourceURL: URL

        func extractCover(from fileURL: URL) async -> Data? {

            try? Data(contentsOf: sourceURL)
        }
    }
}
