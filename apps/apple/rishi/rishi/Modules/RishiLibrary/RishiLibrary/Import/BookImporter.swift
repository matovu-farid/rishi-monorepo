import Foundation



struct BookImporter: Sendable {
    private static let importGate = BookImportGate()
    private static let sourceReservationGate = BookImportGate()

    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let bookIndexingHook: any BookIndexingHook
    private let isTombstoned: (@Sendable (BookID) async -> Bool)?
    private let fingerprintService: BookFingerprintService
    private let fingerprintPersistence: (any BookImportPersistence)?
    private let fingerprintAccountGeneration: @Sendable () async -> UInt64?
    private let materializationCoordinator: BookMaterializationCoordinator?
    private let capturedAccountGeneration: UInt64?
    private let importInstrumentation: BookImportInstrumentation

    private var fileManager: FileManager { .default }

    init(
        rootURL: URL,
        booksDirURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor],
        bookIndexingHook: any BookIndexingHook,
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil,
        fingerprintPersistence: (any BookImportPersistence)? = nil,
        fingerprintAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        materializationCoordinator: BookMaterializationCoordinator? = nil,
        capturedAccountGeneration: UInt64? = nil,
        importInstrumentation: BookImportInstrumentation = .shared
    ) {
        self.rootURL = rootURL
        self.booksDirURL = booksDirURL
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.bookIndexingHook = bookIndexingHook
        self.isTombstoned = isTombstoned
        self.fingerprintService = BookFingerprintService(
            rootURL: rootURL,
            bookStore: bookStore,
            persistence: fingerprintPersistence,
            isTombstoned: isTombstoned
        )
        self.fingerprintPersistence = fingerprintPersistence
        self.fingerprintAccountGeneration = fingerprintAccountGeneration
        self.materializationCoordinator = materializationCoordinator
        self.capturedAccountGeneration = capturedAccountGeneration
        self.importInstrumentation = importInstrumentation
    }

    func importBook(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String? = nil
    ) async throws -> Book {
        if !BookImportInstrumentation.hasActiveImportContext {
            let context = BookImportInstrumentation.Context(
                importID: UUID(),
                accountGeneration: capturedAccountGeneration,
                format: BookFormat(rawValue: sourceURL.pathExtension.lowercased()),
                providerKind: .directURL
            )
            return try await importInstrumentation.withImportContext(context) {
                BookImportInstrumentation.recordCurrent(.requestReceived)
                return try await self.importBook(
                    from: sourceURL,
                    ownerId: ownerId,
                    expectedContentHash: expectedContentHash
                )
            }
        }
        await Self.importGate.acquire()
        do {
            let book = try await importBookWhileHoldingGate(
                from: sourceURL,
                ownerId: ownerId,
                expectedContentHash: expectedContentHash
            )
            await Self.importGate.release()
            return book
        } catch {
            await Self.importGate.release()
            throw error
        }
    }

    func registerSourceReadable(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64
    ) async throws -> SourceReadableBookRegistration {
        try await registerSourceReadable(from: sourceURL, ownerId: ownerId, accountGeneration: accountGeneration, ownedSource: false)
    }

    func registerOwnedSourceReadable(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64
    ) async throws -> SourceReadableBookRegistration {
        try await registerSourceReadable(from: sourceURL, ownerId: ownerId, accountGeneration: accountGeneration, ownedSource: true)
    }

    private func registerSourceReadable(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64,
        ownedSource: Bool
    ) async throws -> SourceReadableBookRegistration {
        if !BookImportInstrumentation.hasActiveImportContext {
            let context = BookImportInstrumentation.Context(
                importID: UUID(),
                accountGeneration: accountGeneration,
                format: BookFormat(rawValue: sourceURL.pathExtension.lowercased()),
                providerKind: ownedSource ? .fileProvider : .directURL
            )
            return try await importInstrumentation.withImportContext(context) {
                BookImportInstrumentation.recordCurrent(.requestReceived)
                return try await self.registerSourceReadable(
                    from: sourceURL,
                    ownerId: ownerId,
                    accountGeneration: accountGeneration,
                    ownedSource: ownedSource
                )
            }
        }
        // Source-readable registrations persist with a tokenized CAS, so probe
        // and hashing work can proceed concurrently across a picker batch.
        // Keep the legacy fallback serialized because it performs the full
        // managed import before returning.
        if materializationCoordinator != nil, fingerprintPersistence != nil {
            return try await registerSourceReadableWhileHoldingGate(
                from: sourceURL,
                ownerId: ownerId,
                accountGeneration: accountGeneration,
                ownedSource: ownedSource
            )
        }
        await Self.importGate.acquire()
        do {
            let registration = try await registerSourceReadableWhileHoldingGate(
                from: sourceURL,
                ownerId: ownerId,
                accountGeneration: accountGeneration,
                ownedSource: ownedSource
            )
            await Self.importGate.release()
            return registration
        } catch {
            await Self.importGate.release()
            throw error
        }
    }

    private func registerSourceReadableWhileHoldingGate(
        from sourceURL: URL,
        ownerId: UserID,
        accountGeneration: UInt64,
        ownedSource: Bool
    ) async throws -> SourceReadableBookRegistration {
        let holdsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if holdsSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try ensureBooksDirExists()
        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: ext)
        }
        let selected: BookFingerprintService.SelectedSource
        do {
            BookImportInstrumentation.recordCurrent(.sourceProbeAndHashStarted)
            selected = try await fingerprintService.probeSelectedSource(
                at: sourceURL,
                metadataExtractor: metadataExtractors[ext]
            )
            BookImportInstrumentation.recordCurrent(
                .sourceProbeAndHashCompleted,
                format: format,
                byteCount: selected.byteCount,
                readableByteCount: selected.byteCount,
                cacheState: .miss
            )
        } catch {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        if let existing = try await fingerprintService.matchingBook(
            ownerID: ownerId,
            byteCount: selected.byteCount,
            sha256: selected.sha256
        ) {
            BookImportInstrumentation.recordCurrent(
                .bookRegistered,
                bookID: existing.id,
                format: format,
                byteCount: selected.byteCount,
                readableByteCount: selected.byteCount,
                cacheState: .hit
            )
            return SourceReadableBookRegistration(book: existing, selectedContentHash: selected.sha256, state: .managed)
        }

        let metadata = selected.metadata
        let deterministicID = DeterministicBookID.make(title: metadata.title, author: metadata.author, format: format)
        var bookID: BookID
        if let deterministicID,
           let isTombstoned,
           await isTombstoned(deterministicID) {
            bookID = UUID()
        } else if let deterministicID,
                  let existing = try await bookStore.book(deterministicID) {
            bookID = UUID()
            Log.event("library.import.identity.rotated", level: .info, data: [
                "existing_book_id": existing.id.uuidString,
                "new_book_id": bookID.uuidString,
                "reason": existing.userId == ownerId ? "content_hash_mismatch" : "different_owner",
            ])
        } else {
            bookID = deterministicID ?? UUID()
        }
        var bookDirectory = booksDirURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
        let destinationURL = bookDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var book = Book(
            id: bookID,
            userId: ownerId,
            title: metadata.title ?? titleFallback(from: sourceURL.lastPathComponent),
            author: metadata.author,
            formatType: format,
            addedAt: Date(),
            openedAt: nil,
            fileURL: relativePath(of: destinationURL),
            coverPath: nil
        )

        guard let materializationCoordinator, let fingerprintPersistence,
              await isTombstoned?(bookID) != true else {
            let managed = try await importBookWhileHoldingGate(from: sourceURL, ownerId: ownerId, expectedContentHash: selected.sha256)
            BookImportInstrumentation.recordCurrent(
                .bookRegistered,
                bookID: managed.id,
                format: format,
                byteCount: selected.byteCount,
                readableByteCount: selected.byteCount,
                cacheState: .miss
            )
            return SourceReadableBookRegistration(book: managed, selectedContentHash: selected.sha256, state: .managed)
        }
        let currentGeneration: UInt64?
        if let capturedAccountGeneration {
            currentGeneration = capturedAccountGeneration
        } else {
            currentGeneration = await fingerprintAccountGeneration()
        }
        guard currentGeneration == accountGeneration else {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        let attemptID = UUID()
        var token = BookMaterializationToken(ownerID: ownerId, accountGeneration: accountGeneration, bookID: bookID, attemptID: attemptID)
        let ownedDirectory = rootURL.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(token.attemptID.uuidString, isDirectory: true)
        let ownedURL = ownedDirectory.appendingPathComponent("source.\(ext)")
        let cleanup = ownedSource ? OwnedImportSourceCleanup(attemptDirectory: ownedDirectory) : nil
        var preserveOwnedDirectory = false
        defer {
            if ownedSource && !preserveOwnedDirectory { try? fileManager.removeItem(at: ownedDirectory) }
        }
        let materializationURL: URL
        let sourceVersion: ManagedFileVersion
        let bookmark: Data?
        if ownedSource {
            do {
                try fileManager.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
                try await fingerprintService.copySelectedSource(at: sourceURL, to: ownedURL, selected: selected)
                guard let stagedVersion = try CoordinatedSourceProbe.version(
                    at: ownedURL,
                    revision: selected.version.materializationRevision
                ), stagedVersion.byteCount == selected.byteCount else {
                    throw BookFileStorage.StorageError.sourceUnreadable
                }
                materializationURL = ownedURL
                sourceVersion = stagedVersion
                bookmark = nil
            } catch {
                try? fileManager.removeItem(at: ownedDirectory)
                if let storageError = error as? BookFileStorage.StorageError { throw storageError }
                throw BookFileStorage.StorageError.sourceUnreadable
            }
        } else {
            do {
                bookmark = try BookSourceBookmarkCodec().makeBookmark(for: sourceURL)
            } catch {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            materializationURL = sourceURL
            sourceVersion = selected.version
        }
        var job = PendingBookMaterialization(
            token: token,
            sourceKind: ownedSource ? .ownedStaging : .securityScopedOriginal,
            sourceBookmark: bookmark,
            ownedSourceRelativePath: ownedSource ? "Imports/\(token.attemptID.uuidString)/source.\(ext)" : nil,
            sourceVersion: sourceVersion,
            expectedSHA256: selected.sha256.lowercased(),
            expectedByteCount: selected.byteCount,
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        BookImportInstrumentation.recordCurrent(
            .reservationStarted,
            bookID: book.id,
            format: format,
            byteCount: selected.byteCount,
            readableByteCount: selected.byteCount,
            cacheState: .miss
        )
        await Self.sourceReservationGate.acquire()
        var admission: BookImportMaterializationAdmission?
        let reservation: BookRegistration
        do {
            // A sibling may have reserved the same deterministic metadata ID
            // while this source was being hashed or staged. Recheck under the
            // short reservation gate before attempting the persistence CAS.
            if let deterministicID, bookID == deterministicID,
               try await bookStore.book(deterministicID) != nil {
                bookID = UUID()
                bookDirectory = booksDirURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
                let destinationURL = bookDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                book = Book(
                    id: bookID,
                    userId: ownerId,
                    title: metadata.title ?? titleFallback(from: sourceURL.lastPathComponent),
                    author: metadata.author,
                    formatType: format,
                    addedAt: Date(),
                    openedAt: nil,
                    fileURL: relativePath(of: destinationURL),
                    coverPath: nil
                )
                token = BookMaterializationToken(ownerID: ownerId, accountGeneration: accountGeneration, bookID: bookID, attemptID: attemptID)
                job = PendingBookMaterialization(
                    token: token,
                    sourceKind: job.sourceKind,
                    sourceBookmark: job.sourceBookmark,
                    ownedSourceRelativePath: job.ownedSourceRelativePath,
                    sourceVersion: job.sourceVersion,
                    expectedSHA256: job.expectedSHA256,
                    expectedByteCount: job.expectedByteCount,
                    stagingRelativePath: job.stagingRelativePath,
                    destinationRelativePath: book.fileURL,
                    phase: job.phase
                )
            }
            guard let admitted = await materializationCoordinator.admitRegistrationAfterRecovery(
                ownerID: ownerId,
                generation: accountGeneration,
                bookID: book.id
            ) else { throw BookFileStorage.StorageError.sourceUnreadable }
            admission = admitted
            do {
                reservation = try await fingerprintPersistence.reserveRegistration(book: book, job: job, candidate: nil)
            } catch BookImportPersistenceError.bookIDOccupied where deterministicID != nil {
                admission?.release()
                bookID = UUID()
                bookDirectory = booksDirURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
                let destinationURL = bookDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                book = Book(
                    id: bookID,
                    userId: ownerId,
                    title: metadata.title ?? titleFallback(from: sourceURL.lastPathComponent),
                    author: metadata.author,
                    formatType: format,
                    addedAt: Date(),
                    openedAt: nil,
                    fileURL: relativePath(of: destinationURL),
                    coverPath: nil
                )
                token = BookMaterializationToken(ownerID: ownerId, accountGeneration: accountGeneration, bookID: bookID, attemptID: attemptID)
                job = PendingBookMaterialization(
                    token: token,
                    sourceKind: job.sourceKind,
                    sourceBookmark: job.sourceBookmark,
                    ownedSourceRelativePath: job.ownedSourceRelativePath,
                    sourceVersion: job.sourceVersion,
                    expectedSHA256: job.expectedSHA256,
                    expectedByteCount: job.expectedByteCount,
                    stagingRelativePath: job.stagingRelativePath,
                    destinationRelativePath: book.fileURL,
                    phase: job.phase
                )
                guard let retryAdmission = await materializationCoordinator.admitRegistrationAfterRecovery(
                    ownerID: ownerId,
                    generation: accountGeneration,
                    bookID: book.id
                ) else { throw BookFileStorage.StorageError.sourceUnreadable }
                admission = retryAdmission
                reservation = try await fingerprintPersistence.reserveRegistration(book: book, job: job, candidate: nil)
            }
            await Self.sourceReservationGate.release()
        } catch {
            admission?.release()
            await Self.sourceReservationGate.release()
            throw error
        }
        BookImportInstrumentation.recordCurrent(
            .reservationCompleted,
            attemptID: reservation.token?.attemptID,
            bookID: reservation.book.id,
            format: format,
            byteCount: selected.byteCount,
            readableByteCount: selected.byteCount,
            cacheState: .miss
        )
        defer { admission?.release() }
        switch reservation.disposition {
        case .registered:
            guard let registeredToken = reservation.token else { throw BookFileStorage.StorageError.sourceUnreadable }
            try await materializationCoordinator.registerReadableSource(
                book: reservation.book,
                token: registeredToken,
                sourceURL: materializationURL,
                requiresSecurityScope: ownedSource ? false : holdsSecurityScope,
                onSourceOwnerReleased: cleanup.map { sourceCleanup in
                    { @Sendable in sourceCleanup.sourceOwnerDidRelease() }
                }
            )
            scheduleSourceReadableMaterialization(
                book: reservation.book,
                token: registeredToken,
                sourceURL: materializationURL,
                fileExtension: ext,
                bookDirectory: bookDirectory,
                sourceCleanup: cleanup
            )
            preserveOwnedDirectory = true
            return SourceReadableBookRegistration(
                book: reservation.book,
                selectedContentHash: selected.sha256,
                state: .copying,
                token: registeredToken
            )
        case .alreadyManaged:
            BookImportInstrumentation.recordCurrent(
                .bookRegistered,
                bookID: reservation.book.id,
                format: format,
                byteCount: selected.byteCount,
                readableByteCount: selected.byteCount,
                cacheState: .hit
            )
            return SourceReadableBookRegistration(
                book: reservation.book,
                selectedContentHash: selected.sha256,
                state: .managed
            )
        case .joinedPending:
            guard (try? await materializationCoordinator.awaitManagedSource(for: reservation.book)) != nil else {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            BookImportInstrumentation.recordCurrent(
                .bookRegistered,
                attemptID: reservation.token?.attemptID,
                bookID: reservation.book.id,
                format: format,
                byteCount: selected.byteCount,
                readableByteCount: selected.byteCount,
                cacheState: .hit
            )
            return SourceReadableBookRegistration(book: reservation.book, selectedContentHash: selected.sha256, state: .managed)
        case .retryRequired, .retried:
            // These dispositions require joining or rotating another attempt.
            // Keep their established lifecycle semantics until the source
            // owner for that attempt can be safely adopted.
            let managed = try await importBookWhileHoldingGate(
                from: materializationURL,
                ownerId: ownerId,
                expectedContentHash: selected.sha256,
                sourceKind: ownedSource ? .ownedStaging : .securityScopedOriginal,
                ownedSourceRelativePath: ownedSource ? relativePath(of: materializationURL) : nil
            )
            return SourceReadableBookRegistration(book: managed, selectedContentHash: selected.sha256, state: .managed)
        }
    }

    private func scheduleSourceReadableMaterialization(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        fileExtension ext: String,
        bookDirectory: URL,
        sourceCleanup: OwnedImportSourceCleanup? = nil
    ) {
        guard let materializationCoordinator else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await materializationCoordinator.materialize(
                    book: book,
                    token: token,
                    sourceURL: sourceURL,
                    reuseRegisteredSource: true
                )
                sourceCleanup?.markMaterialized()
                let managedURL = rootURL.appendingPathComponent(book.fileURL)
                if let extractor = coverExtractors[ext] {
                    _ = await extractAndPersistCover(
                        book: book,
                        token: token,
                        extractor: extractor,
                        sourceURL: managedURL,
                        coverDirectory: bookDirectory
                    )
                }
                NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
                await bookIndexingHook.scheduleIndexing(for: book, fileURL: managedURL)
            } catch {
                Log.event("library.import.materialization.background_failed", level: .info, data: [
                    "book_id": book.id.uuidString,
                    "error": String(describing: error),
                ])
            }
        }
    }

    private func importBookWhileHoldingGate(
        from sourceURL: URL,
        ownerId: UserID,
        expectedContentHash: String?,
        sourceKind: BookSourceKind = .securityScopedOriginal,
        ownedSourceRelativePath: String? = nil
    ) async throws -> Book {
        try ensureBooksDirExists()

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: ext)
        }

        let selectedSource: BookFingerprintService.SelectedSource
        do {
            BookImportInstrumentation.recordCurrent(.sourceProbeAndHashStarted)
            selectedSource = try await fingerprintService.probeSelectedSource(
                at: sourceURL,
                metadataExtractor: metadataExtractors[ext]
            )
            BookImportInstrumentation.recordCurrent(
                .sourceProbeAndHashCompleted,
                format: format,
                byteCount: selectedSource.byteCount,
                readableByteCount: selectedSource.byteCount,
                cacheState: .miss
            )
        } catch {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        if let expectedContentHash,
           selectedSource.sha256.caseInsensitiveCompare(expectedContentHash) != .orderedSame {
            throw BookFileStorage.StorageError.sourceUnreadable
        }

        if let existing = try await fingerprintService.matchingBook(
            ownerID: ownerId,
            byteCount: selectedSource.byteCount,
            sha256: selectedSource.sha256
        ) {
            BookImportInstrumentation.recordCurrent(
                .bookRegistered,
                bookID: existing.id,
                format: format,
                byteCount: selectedSource.byteCount,
                readableByteCount: selectedSource.byteCount,
                cacheState: .hit
            )
            Log.event("library.import.deduplicated", data: [
                "book_id": existing.id.uuidString,
                "format": format.rawValue,
            ])
            return existing
        }

        let metadata = selectedSource.metadata

        let deterministicID = DeterministicBookID.make(
            title: metadata.title,
            author: metadata.author,
            format: format
        )
        let bookId: BookID
        if let deterministicID,
           let isTombstoned,
           await isTombstoned(deterministicID) {
            // A deleted logical book ID is never reused. Re-importing the
            // same source creates a new entity instead of resurrecting a
            // tombstone that may still be pending locally or remotely.
            bookId = UUID()
            Log.event("library.import.identity.rotated", level: .info, data: [
                "deleted_book_id": deterministicID.uuidString,
                "new_book_id": bookId.uuidString,
            ])
        } else if let deterministicID,
                  let existing = try await bookStore.book(deterministicID) {
            // Deterministic metadata identity is only a fallback. If the
            // content hash did not match for this owner, do not overwrite
            // another edition or another user's local record that happens to
            // share its title and author.
            bookId = UUID()
            Log.event("library.import.identity.rotated", level: .info, data: [
                "existing_book_id": existing.id.uuidString,
                "new_book_id": bookId.uuidString,
                "reason": existing.userId == ownerId ? "content_hash_mismatch" : "different_owner",
            ])
        } else {
            bookId = deterministicID ?? UUID()
        }
        let bookDir = booksDirURL.appendingPathComponent(
            bookId.uuidString,
            isDirectory: true
        )
        let filename = sourceURL.lastPathComponent
        let destURL = bookDir.appendingPathComponent(filename)

        let importGeneration: UInt64?
        if let capturedAccountGeneration {
            importGeneration = capturedAccountGeneration
        } else {
            importGeneration = await fingerprintAccountGeneration()
        }
        if let materializationCoordinator,
           let fingerprintPersistence,
           let generation = importGeneration,
           await isTombstoned?(bookId) != true {
            let book = Book(
                id: bookId,
                userId: ownerId,
                title: metadata.title ?? titleFallback(from: filename),
                author: metadata.author,
                formatType: format,
                addedAt: Date(),
                openedAt: nil,
                fileURL: relativePath(of: destURL),
                coverPath: nil
            )
            let token = BookMaterializationToken(ownerID: ownerId, accountGeneration: generation, bookID: bookId, attemptID: UUID())
            let stagingRelativePath = "Imports/\(token.attemptID.uuidString)/content.partial"
            let ownedAttemptDirectory = rootURL.appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent(token.attemptID.uuidString, isDirectory: true)
            let ownedAttemptCleanup: OwnedImportSourceCleanup?
            if case .ownedStaging = sourceKind {
                ownedAttemptCleanup = OwnedImportSourceCleanup(attemptDirectory: ownedAttemptDirectory)
            } else {
                ownedAttemptCleanup = nil
            }
            var preserveOwnedAttempt = false
            var uncommittedRetryDirectories: [URL] = []
            let retryDirectoryOwnership = OwnedImportSourceDirectoryOwnership()
            defer {
                if case .ownedStaging = sourceKind, !preserveOwnedAttempt {
                    try? fileManager.removeItem(at: ownedAttemptDirectory)
                }
                for directory in uncommittedRetryDirectories where !retryDirectoryOwnership.wasTransferred(directory) {
                    try? fileManager.removeItem(at: directory)
                }
            }
            let materializationSourceURL: URL
            let sourceVersion: ManagedFileVersion
            let bookmark: Data?
            var materializationOwnedSourcePath = ownedSourceRelativePath
            if case .ownedStaging = sourceKind {
                let ownedURL = ownedAttemptDirectory.appendingPathComponent("source.\(format.rawValue)")
                try fileManager.createDirectory(at: ownedAttemptDirectory, withIntermediateDirectories: true)
                try await fingerprintService.copySelectedSource(at: sourceURL, to: ownedURL, selected: selectedSource)
                guard let ownedVersion = try CoordinatedSourceProbe.version(
                    at: ownedURL,
                    revision: selectedSource.version.materializationRevision
                ), ownedVersion.byteCount == selectedSource.byteCount else {
                    throw BookFileStorage.StorageError.sourceUnreadable
                }
                materializationSourceURL = ownedURL
                sourceVersion = ownedVersion
                materializationOwnedSourcePath = "Imports/\(token.attemptID.uuidString)/source.\(format.rawValue)"
                bookmark = nil
            } else {
                do {
                    bookmark = try BookSourceBookmarkCodec().makeBookmark(for: sourceURL)
                } catch {
                    throw BookFileStorage.StorageError.sourceUnreadable
                }
                materializationSourceURL = sourceURL
                sourceVersion = selectedSource.version
            }
            let job = PendingBookMaterialization(
                token: token,
                sourceKind: sourceKind,
                sourceBookmark: bookmark,
                ownedSourceRelativePath: materializationOwnedSourcePath,
                sourceVersion: sourceVersion,
                expectedSHA256: selectedSource.sha256.lowercased(),
                expectedByteCount: selectedSource.byteCount,
                stagingRelativePath: stagingRelativePath,
                destinationRelativePath: book.fileURL,
                phase: .registered
            )
            var registrationAdmission = await materializationCoordinator.admitRegistrationAfterRecovery(
                ownerID: ownerId,
                generation: generation,
                bookID: book.id
            )
            guard registrationAdmission != nil else { throw BookFileStorage.StorageError.sourceUnreadable }
            defer { registrationAdmission?.release() }
            BookImportInstrumentation.recordCurrent(
                .reservationStarted,
                bookID: book.id,
                format: format,
                byteCount: selectedSource.byteCount,
                readableByteCount: selectedSource.byteCount,
                cacheState: .miss
            )
            await Self.sourceReservationGate.acquire()
            let reservation: BookRegistration
            do {
                reservation = try await fingerprintPersistence.reserveRegistration(book: book, job: job, candidate: nil)
                await Self.sourceReservationGate.release()
                } catch BookImportPersistenceError.bookIDOccupied where deterministicID != nil {
                await Self.sourceReservationGate.release()
                // A source-readable registration may have won the same
                // deterministic metadata identity while this durable import
                // was preparing. Re-probe once; the canonical row will now
                // force the usual random-ID rotation.
                return try await importBookWhileHoldingGate(
                    from: sourceURL,
                    ownerId: ownerId,
                    expectedContentHash: expectedContentHash,
                    sourceKind: sourceKind,
                    ownedSourceRelativePath: ownedSourceRelativePath
                )
            } catch {
                await Self.sourceReservationGate.release()
                throw error
            }
            BookImportInstrumentation.recordCurrent(
                .reservationCompleted,
                attemptID: reservation.token?.attemptID,
                bookID: reservation.book.id,
                format: format,
                byteCount: selectedSource.byteCount,
                readableByteCount: selectedSource.byteCount,
                cacheState: .miss
            )
            var registration = reservation
            switch reservation.disposition {
            case .registered:
                guard let registeredToken = reservation.token else { throw BookFileStorage.StorageError.sourceUnreadable }
                if case .ownedStaging = sourceKind { preserveOwnedAttempt = true }
                let admission = registrationAdmission
                registrationAdmission = nil
                _ = try await materializationCoordinator.materialize(
                    book: reservation.book,
                    token: registeredToken,
                    sourceURL: materializationSourceURL,
                    publishRegistration: true,
                    onSourceOwnerReleased: ownedAttemptCleanup.map { cleanup in
                        { @Sendable in cleanup.sourceOwnerDidRelease() }
                    },
                    admission: admission
                )
                BookImportInstrumentation.recordCurrent(
                    .bookRegistered,
                    attemptID: registeredToken.attemptID,
                    bookID: reservation.book.id,
                    format: format,
                    byteCount: selectedSource.byteCount,
                    readableByteCount: selectedSource.byteCount,
                    cacheState: .miss
                )
                ownedAttemptCleanup?.markMaterialized()
                preserveOwnedAttempt = false
            case .joinedPending:
                registrationAdmission?.release()
                registrationAdmission = nil
                _ = try await materializationCoordinator.awaitManagedSource(for: reservation.book)
            case .alreadyManaged:
                registrationAdmission?.release()
                registrationAdmission = nil
                BookImportInstrumentation.recordCurrent(
                    .bookRegistered,
                    bookID: reservation.book.id,
                    format: format,
                    byteCount: selectedSource.byteCount,
                    readableByteCount: selectedSource.byteCount,
                    cacheState: .hit
                )
                return reservation.book
            case .retryRequired:
                guard var retiredJob = try await fingerprintPersistence.pendingMaterializationForRecovery(
                    bookID: reservation.book.id,
                    ownerID: ownerId,
                    currentGeneration: generation
                ) else { throw BookFileStorage.StorageError.sourceUnreadable }
                let retryToken = BookMaterializationToken(ownerID: ownerId, accountGeneration: generation, bookID: reservation.book.id, attemptID: UUID())
                var retrySourceURL = materializationSourceURL
                var retrySourceVersion = sourceVersion
                var retryOwnedSourcePath = materializationOwnedSourcePath
                var retryOwnedDirectory: URL?
                var retryOwnedCleanup: OwnedImportSourceCleanup?
                if case .ownedStaging = sourceKind {
                    let retryDirectory = rootURL.appendingPathComponent("Imports", isDirectory: true)
                        .appendingPathComponent(retryToken.attemptID.uuidString, isDirectory: true)
                    uncommittedRetryDirectories.append(retryDirectory)
                    retryOwnedDirectory = retryDirectory
                    retryOwnedCleanup = OwnedImportSourceCleanup(attemptDirectory: retryDirectory)
                    let retryURL = retryDirectory.appendingPathComponent("source.\(format.rawValue)")
                    try fileManager.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
                    let retrySelected = BookFingerprintService.SelectedSource(
                        sha256: selectedSource.sha256,
                        byteCount: selectedSource.byteCount,
                        metadata: selectedSource.metadata,
                        version: sourceVersion
                    )
                    try await fingerprintService.copySelectedSource(at: materializationSourceURL, to: retryURL, selected: retrySelected)
                    guard let retryVersion = try CoordinatedSourceProbe.version(
                        at: retryURL,
                        revision: sourceVersion.materializationRevision
                    ), retryVersion.byteCount == selectedSource.byteCount else {
                        throw BookFileStorage.StorageError.sourceUnreadable
                    }
                    retrySourceURL = retryURL
                    retrySourceVersion = retryVersion
                    retryOwnedSourcePath = "Imports/\(retryToken.attemptID.uuidString)/source.\(format.rawValue)"
                }
                let retryJob = PendingBookMaterialization(
                    token: retryToken,
                    sourceKind: sourceKind,
                    sourceBookmark: bookmark,
                    ownedSourceRelativePath: retryOwnedSourcePath,
                    sourceVersion: retrySourceVersion,
                    expectedSHA256: selectedSource.sha256.lowercased(),
                    expectedByteCount: selectedSource.byteCount,
                    stagingRelativePath: "Imports/\(retryToken.attemptID.uuidString)/content.partial",
                    destinationRelativePath: reservation.book.fileURL,
                    phase: .registered
                )
                if registrationAdmission?.bookID != reservation.book.id {
                    guard let canonicalAdmission = await materializationCoordinator.admitRegistrationAfterRecovery(
                        ownerID: ownerId,
                        generation: generation,
                        bookID: reservation.book.id
                    ) else { throw BookFileStorage.StorageError.sourceUnreadable }
                    registrationAdmission?.release()
                    registrationAdmission = canonicalAdmission
                }
                if let currentJob = try await fingerprintPersistence.pendingMaterializationForRecovery(
                    bookID: reservation.book.id,
                    ownerID: ownerId,
                    currentGeneration: generation
                ), currentJob.token != retiredJob.token {
                    if currentJob.phase == .paused || currentJob.phase == .failed || currentJob.phase == .cancelled {
                        retiredJob = currentJob
                    } else {
                        registrationAdmission?.release()
                        registrationAdmission = nil
                        _ = try await materializationCoordinator.awaitManagedSource(for: reservation.book)
                        if let retryOwnedDirectory { try? fileManager.removeItem(at: retryOwnedDirectory) }
                        registration = BookRegistration(
                            book: reservation.book,
                            token: currentJob.token,
                            disposition: .joinedPending
                        )
                        break
                    }
                } else if let currentJob = try await fingerprintPersistence.pendingMaterializationForRecovery(
                    bookID: reservation.book.id,
                    ownerID: ownerId,
                    currentGeneration: generation
                ), currentJob.phase == .ready {
                    registrationAdmission?.release()
                    registrationAdmission = nil
                    _ = try await materializationCoordinator.awaitManagedSource(for: reservation.book)
                    if let retryOwnedDirectory { try? fileManager.removeItem(at: retryOwnedDirectory) }
                    registration = BookRegistration(book: reservation.book, token: currentJob.token, disposition: .joinedPending)
                    break
                }
                let admission = registrationAdmission
                registrationAdmission = nil
                registration = try await materializationCoordinator.retryAndMaterialize(
                    book: reservation.book,
                    newSource: retryJob,
                    retiredAttempt: RetiredBookMaterializationAttempt(token: retiredJob.token),
                    sourceURL: retrySourceURL,
                    publishRegistration: true,
                    onSourceOwnerReleased: retryOwnedCleanup.map { cleanup in
                        { @Sendable in cleanup.sourceOwnerDidRelease() }
                    },
                    onRegistrationAccepted: retryOwnedDirectory.map { directory in
                        { @Sendable in retryDirectoryOwnership.markTransferred(directory) }
                    },
                    admission: admission
                )
                retryOwnedCleanup?.markMaterialized()
            case .retried:
                guard let retriedToken = reservation.token else { throw BookFileStorage.StorageError.sourceUnreadable }
                if registrationAdmission?.bookID != reservation.book.id {
                    guard let canonicalAdmission = await materializationCoordinator.admitRegistrationAfterRecovery(
                        ownerID: ownerId,
                        generation: generation,
                        bookID: reservation.book.id
                    ) else { throw BookFileStorage.StorageError.sourceUnreadable }
                    registrationAdmission?.release()
                    registrationAdmission = canonicalAdmission
                }
                let admission = registrationAdmission
                registrationAdmission = nil
                _ = try await materializationCoordinator.materialize(book: reservation.book, token: retriedToken, sourceURL: sourceURL, publishRegistration: true, admission: admission)
            }

            var readyBook = registration.book
            let readyURL = rootURL.appendingPathComponent(readyBook.fileURL)
            if let extractor = coverExtractors[ext], let coverToken = registration.token {
                if materializationCoordinator.hasImportEventFeed {
                    // Once the verified managed copy is ready, image decode,
                    // PDF page rendering and cache writes proceed on utility
                    // work. The normal fallback remains visible meanwhile.
                    let backgroundBook = readyBook
                    Task.detached(priority: .utility) {
                        await self.extractAndPersistCover(
                            book: backgroundBook, token: coverToken, extractor: extractor,
                            sourceURL: readyURL, coverDirectory: bookDir
                        )
                    }
                } else {
                    readyBook = await extractAndPersistCover(
                        book: readyBook, token: coverToken, extractor: extractor,
                        sourceURL: readyURL, coverDirectory: bookDir
                    ) ?? readyBook
                }
            }
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            await bookIndexingHook.scheduleIndexing(for: readyBook, fileURL: readyURL)
            return readyBook
        }

        try fileManager.createDirectory(
            at: bookDir,
            withIntermediateDirectories: true
        )
        let stagingURL = bookDir.appendingPathComponent(".\(filename).importing-\(UUID().uuidString)")
        do {
            try await fingerprintService.copySelectedSource(at: sourceURL, to: stagingURL, selected: selectedSource)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw BookFileStorage.StorageError.copyFailed(underlying: error)
        }

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
                        data: [
                            "book": bookId.uuidString,
                            "error": String(describing: error),
                        ]
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
        BookImportInstrumentation.recordCurrent(
            .bookRegistered,
            bookID: book.id,
            format: book.formatType,
            byteCount: selectedSource.byteCount,
            readableByteCount: selectedSource.byteCount,
            cacheState: .miss
        )
        if let fingerprintPersistence,
           let generation = await fingerprintAccountGeneration(),
           await isTombstoned?(book.id) != true {
            try? await fingerprintPersistence.setBookReadingAuthorization(
                bookID: book.id,
                ownerID: ownerId,
                generation: generation,
                contentRevision: UUID(),
                tombstoned: false
            )
        }
        await fingerprintService.verifyAndCacheManagedFile(for: book, expectedSHA256: selectedSource.sha256)
        NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)

        await bookIndexingHook.scheduleIndexing(for: book, fileURL: destURL)
        return book
    }

    private func extractAndPersistCover(
        book: Book,
        token: BookMaterializationToken,
        extractor: any CoverExtractor,
        sourceURL: URL,
        coverDirectory: URL
    ) async -> Book? {
        guard let materializationCoordinator else { return nil }
        guard let effect = await materializationCoordinator.admitReadyBookEffect(token: token) else { return nil }
        defer { effect.release() }
        importInstrumentation.record(.coverExtractionStarted, attemptID: token.attemptID)
        let png = await extractor.extractCover(from: sourceURL)
        importInstrumentation.record(.coverExtractionCompleted, attemptID: token.attemptID)
        guard let png else {
            await materializationCoordinator.publishCoverFailed(bookID: book.id, token: token)
            return nil
        }
        // Attempt-namespaced files ensure a late extractor cannot overwrite a
        // cover already referenced by a newer content attempt.
        let coverURL = coverDirectory.appendingPathComponent("cover-\(token.attemptID.uuidString).png")
        do {
            try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            try png.write(to: coverURL, options: .atomic)
            let coverPath = relativePath(of: coverURL)
            guard let fingerprintPersistence,
                  try await fingerprintPersistence.patchCover(bookID: book.id, token: token, relativePath: coverPath) else {
                try? FileManager.default.removeItem(at: coverURL)
                return nil
            }
            importInstrumentation.record(.coverPublished, attemptID: token.attemptID)
            await materializationCoordinator.publishCoverReady(bookID: book.id, token: token)
            return Book(
                id: book.id, userId: book.userId, title: book.title,
                author: book.author, formatType: book.formatType,
                addedAt: book.addedAt, openedAt: book.openedAt,
                fileURL: book.fileURL, coverPath: coverPath
            )
        } catch {
            try? FileManager.default.removeItem(at: coverURL)
            Log.event("cover.write.failed", level: .info, data: ["book": book.id.uuidString, "error": String(describing: error)])
            await materializationCoordinator.publishCoverFailed(bookID: book.id, token: token)
            return nil
        }
    }

    private func ensureBooksDirExists() throws {
        if !fileManager.fileExists(atPath: booksDirURL.path) {
            try fileManager.createDirectory(
                at: booksDirURL,
                withIntermediateDirectories: true
            )
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

/// Serializes imports so the hash check and the subsequent store write are
/// one logical operation. Without this gate, two simultaneous imports of the
/// same bytes could both observe an empty library and create two UUIDs when
/// their metadata differs.
private actor BookImportGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}
