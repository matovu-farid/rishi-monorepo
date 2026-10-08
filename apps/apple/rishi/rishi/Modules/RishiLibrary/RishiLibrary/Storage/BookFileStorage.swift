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
    public enum SampleRepairResult: Sendable {
        case repaired(Book)
        case alreadyManaged(Book)
    }
    public enum StorageError: Error, Sendable {
        case sourceUnreadable
        case copyFailed(underlying: Error)
        case unsupportedFormat(ext: String)
        case bookNotFound
        case bookOwnerMismatch
        case staleDeletionCleanup
        case sampleProvenanceUnavailable
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

    public func repairMissingSample(
        for book: Book,
        from sourceURL: URL,
        ownerID: UserID,
        accountGeneration: UInt64
    ) async throws -> SampleRepairResult {
        guard book.formatType == .epub, book.userId == ownerID,
              let persistence = fingerprintPersistence,
              let coordinator = materializationCoordinator,
              await fingerprintAccountGeneration() == accountGeneration,
              let canonical = try await bookStore.book(book.id), canonical == book,
              await isTombstoned?(book.id) != true else { throw StorageError.bookNotFound }
        let existingFingerprint = try await persistence.sampleRepairFingerprint(bookID: book.id, ownerID: ownerID)
        guard let existingFingerprint,
              existingFingerprint.bookID == book.id,
              existingFingerprint.ownerID == ownerID else { throw StorageError.sourceUnreadable }
        let observedPrior = try await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID)
        let observedPriorToken = observedPrior?.token
        let revision = UUID()
        let source = try await CoordinatedSourceProbe().probe(sourceURL, materializationRevision: revision)
        guard source.sha256.caseInsensitiveCompare(existingFingerprint.sha256) == .orderedSame,
              source.byteCount == existingFingerprint.version.byteCount,
              await fingerprintAccountGeneration() == accountGeneration else { throw StorageError.sourceUnreadable }
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: accountGeneration, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: source.version,
            expectedSHA256: existingFingerprint.sha256, expectedByteCount: source.byteCount,
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .registered
        )
        let managedURL = rootURL.appendingPathComponent(book.fileURL).standardizedFileURL
        let currentVersion = try FileManagedFileVersionInspector().managedFileVersion(
            at: managedURL, materializationRevision: existingFingerprint.version.materializationRevision
        )
        let request = SampleRepairReservationRequest(
            expectedBook: book, expectedFingerprint: existingFingerprint,
            canonicalManagedURL: managedURL, expectedManagedFileVersion: currentVersion,
            expectedPriorPendingToken: observedPriorToken, job: job
        )
        switch try await coordinator.materializeReservedSampleRepair(request: request, sourceURL: sourceURL) {
        case .alreadyManaged(let fingerprint):
            guard fingerprint == existingFingerprint,
                  await fingerprintAccountGeneration() == accountGeneration,
                  await coordinator.publishReconciledManagedReady(book: book, generation: accountGeneration, fingerprint: fingerprint) else {
                throw StorageError.sourceUnreadable
            }
            return .alreadyManaged(book)
        case .repaired(let fingerprint):
            guard fingerprint.sha256.caseInsensitiveCompare(existingFingerprint.sha256) == .orderedSame,
                  await fingerprintAccountGeneration() == accountGeneration else { throw StorageError.sourceUnreadable }
            return .repaired(book)
        }
    }

    /// Installs bundled sample content, repairing an exact-provenance stale
    /// EPUB row before ordinary import can assign the bytes a new identity.
    public func installOrRepairSample(
        from sourceURL: URL,
        ownerID: UserID,
        accountGeneration: UInt64
    ) async throws -> Book {
        if let fingerprintPersistence {
            let source = try await CoordinatedSourceProbe().probe(
                sourceURL,
                materializationRevision: UUID(),
                metadataExtractor: metadataExtractors[sourceURL.pathExtension.lowercased()]
            )
            let candidates = try await bookStore.books(for: ownerID)
            let sampleMetadataID = DeterministicBookID.make(
                title: bookDisplayTitle(metadataTitle: source.metadata.title, filename: sourceURL.lastPathComponent),
                author: source.metadata.author,
                format: .epub
            )
            for candidate in candidates where candidate.formatType == .epub {
                guard await isTombstoned?(candidate.id) != true else { continue }
                let saved = try await fingerprintPersistence.sampleRepairFingerprint(
                    bookID: candidate.id, ownerID: ownerID
                )
                let provenanceMatches = saved?.sha256.caseInsensitiveCompare(source.sha256) == .orderedSame &&
                    saved?.version.byteCount == source.byteCount
                if provenanceMatches {
                    switch try await repairMissingSample(
                        for: candidate, from: sourceURL, ownerID: ownerID, accountGeneration: accountGeneration
                    ) {
                    case .repaired(let book), .alreadyManaged(let book): return book
                    }
                }
                let candidateMetadataID = DeterministicBookID.make(
                    title: candidate.title, author: candidate.author, format: candidate.formatType
                )
                if candidateMetadataID == sampleMetadataID,
                   !(await isReadableSourceAvailable(
                    for: candidate, ownerID: ownerID, accountGeneration: accountGeneration
                   )) {
                    throw StorageError.sampleProvenanceUnavailable
                }
            }
        }
        return try await importBook(from: sourceURL, ownerId: ownerID, expectedContentHash: nil, accountGeneration: accountGeneration)
    }

    public func isReadableSourceAvailable(for book: Book, ownerID: UserID, accountGeneration: UInt64) async -> Bool {
        let currentGeneration = await fingerprintAccountGeneration()
        guard book.userId == ownerID,
              let canonical = try? await bookStore.book(book.id), canonical == book,
              currentGeneration == nil || currentGeneration == accountGeneration,
              await isTombstoned?(book.id) != true else { return false }
        guard let url = validatedManagedBookURL(canonical),
              fileManager.fileExists(atPath: url.path) else { return false }
        guard let materializationCoordinator else { return true }
        return await materializationCoordinator.isReadableSourceAvailable(for: canonical)
    }

    public func checkedValidateSourceReadableRegistration(_ registration: SourceReadableBookRegistration, ownerId: UserID, accountGeneration: UInt64) async throws {
        guard registration.book.userId == ownerId,
              registration.token == nil || (registration.token?.ownerID == ownerId && registration.token?.accountGeneration == accountGeneration) else { throw StorageError.sourceUnreadable }
        let current = await fingerprintAccountGeneration()
        guard current == nil || current == accountGeneration else { throw StorageError.sourceUnreadable }
        func checkRetirement() throws {
            if materializationCoordinator?.isBookRetiredForDeletion(ownerID: ownerId, generation: accountGeneration, bookID: registration.book.id) == true { throw BookImportFailure.deletionInProgress }
        }
        try checkRetirement()
        let valid = await validateSourceReadableRegistration(registration, ownerId: ownerId, accountGeneration: accountGeneration)
        guard await fingerprintAccountGeneration() == current else { throw StorageError.sourceUnreadable }
        try checkRetirement()
        guard valid else { throw StorageError.sourceUnreadable }
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
              validatedManagedBookURL(canonical) != nil,
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
        guard let managedURL = validatedManagedBookURL(canonical),
              fileManager.fileExists(atPath: managedURL.path) else { return false }
        if let materializationCoordinator {
            return await materializationCoordinator.isReadableSourceAvailable(for: canonical)
        }
        return true
    }

    /// Persisted Book paths are untrusted input. Require a canonical managed
    /// relative path below Books before any readability or fingerprint query.
    private func validatedManagedBookURL(_ book: Book) -> URL? {
        let relative = book.fileURL
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              relative.hasPrefix("Books/") else { return nil }
        let target = rootURL.appendingPathComponent(relative)
        guard let validated = try? ManagedRelativePath.make(root: rootURL, target: target),
              validated == relative,
              validated.hasPrefix("Books/") else { return nil }
        return rootURL.appendingPathComponent(validated).standardizedFileURL
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
            if let fingerprintPersistence {
                let current = try await fingerprintPersistence.pendingMaterializationForDeletionCleanup(bookID: bookID, ownerID: ownerID)
                guard current?.token == pending?.token || current == nil else { throw StorageError.staleDeletionCleanup }
            }
            try await removeManagedMaterial(forBookID: bookID)
            if let stagingDirectory, fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
            if let pending, let fingerprintPersistence {
                guard try await fingerprintPersistence.deletePendingMaterializationForDeletionCleanup(
                    bookID: bookID,
                    ownerID: ownerID,
                    expectedToken: pending.token
                ) else {
                    guard try await fingerprintPersistence.pendingMaterializationForDeletionCleanup(bookID: bookID, ownerID: ownerID) == nil else { throw StorageError.staleDeletionCleanup }
                    return
                }
            }
        }
    }

    public func isPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool {
        try await fingerprintPersistence?.isBookPermanentlyDeleted(bookID: bookID, ownerID: ownerID) ?? false
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

    /// Returns only artwork that already exists for the canonical library row.
    /// This path never opens the book payload, invokes an extractor, or writes
    /// to the cover cache.
    public func existingArtworkURL(for book: Book) async throws -> URL? {
        let canonical = try await validateArtworkBook(book)
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let booksRoot = root.appendingPathComponent("Books", isDirectory: true)
        let expectedBookDirectory = booksRoot.appendingPathComponent(book.id.uuidString, isDirectory: true)
        let resolvedBooksRoot = booksRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBookDirectory = expectedBookDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBooksRoot.path == booksRoot.standardizedFileURL.path,
              resolvedBookDirectory.path == expectedBookDirectory.standardizedFileURL.path,
              Self.isContained(resolvedBookDirectory, in: resolvedBooksRoot),
              Self.isContained(resolvedBookDirectory, in: root) else { throw StorageError.sourceUnreadable }

        let bookSource = try Self.validatedRelativeURL(
            canonical.fileURL, under: root, directory: expectedBookDirectory
        )
        let coverSource: URL?
        if let coverPath = canonical.coverPath {
            let candidate = try Self.validatedRelativeURL(coverPath, under: root, directory: expectedBookDirectory)
            guard Self.isOwnedArtworkFilename(candidate.lastPathComponent),
                  candidate.deletingLastPathComponent().standardizedFileURL == expectedBookDirectory.standardizedFileURL else {
                throw StorageError.sourceUnreadable
            }
            try Self.rejectBookPayloadAlias(candidate, bookSource: bookSource)
            coverSource = candidate
        } else {
            coverSource = nil
        }

        let cacheDirectory = root.appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("book-covers", isDirectory: true)
        let cacheURL = cacheDirectory.appendingPathComponent("\(book.id.uuidString).heic")
        let sidecarURL = cacheDirectory.appendingPathComponent("\(book.id.uuidString).mtime")
        let cacheNamespace = root.appendingPathComponent("Caches", isDirectory: true)
        let resolvedCacheNamespace = cacheNamespace.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCacheDirectory = cacheDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCacheNamespace.path == cacheNamespace.standardizedFileURL.path,
              resolvedCacheDirectory.path == cacheDirectory.standardizedFileURL.path,
              Self.isContained(resolvedCacheDirectory, in: resolvedCacheNamespace),
              Self.isContained(resolvedCacheDirectory, in: root) else { throw StorageError.sourceUnreadable }
        try Self.validateResolvedPath(cacheURL, within: resolvedCacheDirectory)
        try Self.validateResolvedPath(sidecarURL, within: resolvedCacheDirectory)
        try Self.rejectBookPayloadAlias(cacheURL, bookSource: bookSource)
        try Self.rejectBookPayloadAlias(sidecarURL, bookSource: bookSource)

        var result: URL?
        if let cache = coverCache {
            if let coverSource,
               await Self.fileExistsOffActor(path: coverSource.path) {
                result = cache.cachedURLIfFresh(for: book.id, sourceFileURL: coverSource)
                if result == nil { result = coverSource }
            } else {
                result = cache.cachedURLIfFresh(for: book.id, sourceFileURL: bookSource)
            }
        } else if let coverSource, await Self.fileExistsOffActor(path: coverSource.path) {
            result = coverSource
        }

        if let candidate = result {
            try Self.validateResolvedPath(candidate, within: resolvedCacheDirectory, allowRawBookImage: true, bookDirectory: resolvedBookDirectory)
            if !(await Self.fileExistsOffActor(path: candidate.path)) { result = nil }
        }
        _ = try await validateArtworkBook(book)
        return result
    }

    private func validateArtworkBook(_ book: Book) async throws -> Book {
        guard let canonical = try await bookStore.book(book.id) else { throw StorageError.bookNotFound }
        guard canonical.userId == book.userId else { throw StorageError.bookOwnerMismatch }
        guard canonical == book, await isTombstoned?(book.id) != true else { throw StorageError.bookNotFound }
        return canonical
    }

    private nonisolated static func validatedRelativeURL(_ path: String, under root: URL, directory: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !components.contains(".."), !components.contains(".") else { throw StorageError.sourceUnreadable }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolvedDirectory, in: resolvedRoot) else { throw StorageError.sourceUnreadable }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard isContained(candidate, in: directory.standardizedFileURL) else { throw StorageError.sourceUnreadable }
        try validateResolvedPath(candidate, within: resolvedDirectory)
        return candidate
    }

    private nonisolated static func validateResolvedPath(
        _ candidate: URL,
        within namespace: URL,
        allowRawBookImage: Bool = false,
        bookDirectory: URL? = nil
    ) throws {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let insideCache = isContained(resolved, in: namespace)
        let insideBook = allowRawBookImage && bookDirectory.map { isContained(resolved, in: $0) } == true
        guard insideCache || insideBook else { throw StorageError.sourceUnreadable }
    }

    private nonisolated static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
    }

    private nonisolated static func isOwnedArtworkFilename(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension.lowercased() == "png" else { return false }
        if url.deletingPathExtension().lastPathComponent == "cover" { return true }
        let prefix = "cover-"
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil
    }

    private nonisolated static func rejectBookPayloadAlias(_ candidate: URL, bookSource: URL) throws {
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = bookSource.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.standardizedFileURL != bookSource.standardizedFileURL,
              resolvedCandidate != resolvedSource,
              !sharesFileIdentity(candidate, bookSource) else { throw StorageError.sourceUnreadable }
    }

    private nonisolated static func sharesFileIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsAttributes = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let rhsAttributes = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let lhsDevice = (lhsAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let rhsDevice = (rhsAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let lhsFile = (lhsAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let rhsFile = (rhsAttributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return false }
        return lhsDevice == rhsDevice && lhsFile == rhsFile
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
            isTombstoned: isTombstoned,
            currentGeneration: fingerprintAccountGeneration
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
    public func persistVerifiedFingerprint(_ fingerprint: BookFileFingerprint, for book: Book, expectedGeneration: UInt64) async -> Bool {
        guard fingerprintPersistence != nil,
              fingerprint.bookID == book.id,
              fingerprint.ownerID == book.userId,
              await isTombstoned?(book.id) != true,
              let persistence = fingerprintPersistence else { return false }
        return (try? await persistence.cacheManagedFingerprint(
            fingerprint,
            expectedGeneration: expectedGeneration,
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
