import Foundation

/// Sequential assembly of the existing book source, materialization and recovery owners.
enum BookDomainFactory {
    static func make(documentsURL: URL, bookStore: any BookStore, bookImportPersistence: any BookImportPersistence,
        syncMetadataStore: any SyncMetadataStore, userIdBox: UserIdBox,
        fingerprintAccountGeneration: @escaping @Sendable () async -> UInt64?, indexBuilder: IndexBuilder,
        pdfFooterPolicy: FooterDropPolicy, chapterIndexGenerationDispatcher: ChapterIndexGenerationDispatcher,
        onManagedReady: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in }
    ) async -> BookDomainResources {
        let managedFingerprintStorage = BookFileStorage(
            rootURL: documentsURL,
            bookStore: bookStore,
            coverExtractors: [:],
            isTombstoned: { bookId in
                (try? await syncMetadataStore.isTombstone(entityId: bookId, kind: .book)) ?? false
            },
            fingerprintPersistence: bookImportPersistence,
            fingerprintAccountGeneration: fingerprintAccountGeneration
        )
        let bookSourceRegistry = BookSourceRegistry(
            persistence: bookImportPersistence,
            currentGeneration: { await fingerprintAccountGeneration() ?? 0 },
            currentOwnerID: { await userIdBox.value },
            backfillManagedFingerprintIfNeeded: { book in
                guard (try? await syncMetadataStore.isTombstone(entityId: book.id, kind: .book)) == false else { return false }
                return await managedFingerprintStorage.cacheVerifiedManagedFile(for: book)?.fingerprintPersisted == true
            },
            managedURL: { book in documentsURL.appendingPathComponent(book.fileURL) }
        )
        let indexingHook = RishiSearchIndexingHook(
            builder: indexBuilder,
            extractors: [
                "pdf": PdfTextExtractor(footerPolicy: pdfFooterPolicy),
                "epub": EpubTextExtractor(),
            ],
            onIndexReady: { bookID in
                await chapterIndexGenerationDispatcher.refresh(bookID)
            },
            acquireSource: { requested in
                guard await userIdBox.value == requested.userId,
                      let generation = await fingerprintAccountGeneration(),
                      let canonical = try await bookStore.book(requested.id),
                      canonical.userId == requested.userId,
                      canonical.fileURL == requested.fileURL,
                      canonical.formatType == requested.formatType,
                      try await syncMetadataStore.isTombstone(entityId: requested.id, kind: .book) == false,
                      let managed = try await bookSourceRegistry.managedSource(for: canonical),
                      managed.accountGeneration == generation else { throw CancellationError() }
                let lease = try await bookSourceRegistry.acquireReadableSource(for: canonical)
                guard await userIdBox.value == requested.userId,
                      await fingerprintAccountGeneration() == generation,
                      try await bookStore.book(requested.id) == canonical,
                      try await syncMetadataStore.isTombstone(entityId: requested.id, kind: .book) == false,
                      lease.access == .account(managed.readingPermit),
                      lease.cachePolicy == .managed(bookID: requested.id, version: managed.fingerprint.version),
                      lease.url.standardizedFileURL == managed.url.standardizedFileURL,
                      await userIdBox.value == requested.userId,
                      await fingerprintAccountGeneration() == generation else { throw CancellationError() }
                return BookIndexingSource(
                    identity: BookIndexingIdentity(ownerID: requested.userId, generation: generation, bookID: requested.id),
                    lease: lease
                )
            }
        )
        let bookImportLifecycle = BookImportLifecycle(
            sourceRegistry: bookSourceRegistry,
            currentAccountGeneration: { await fingerprintAccountGeneration() },
            cancelOwnerWork: { ownerID, generation in
                indexingHook.cancelOwner(ownerID: ownerID, generation: generation)
            },
            drainOwnerWork: { ownerID, generation in
                await indexingHook.drainOwner(ownerID: ownerID, generation: generation)
            },
            cancelBookWork: { ownerID, generation, bookID in
                indexingHook.cancelBook(ownerID: ownerID, generation: generation, bookID: bookID)
            },
            drainBookWork: { ownerID, generation, bookID in
                await indexingHook.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
            }
        )
        let bookImportEvents = BookImportEvents()
        let bookMaterializationCoordinator = BookMaterializationCoordinator(
            rootURL: documentsURL,
            lifecycle: bookImportLifecycle,
            sourceRegistry: bookSourceRegistry,
            persistence: bookImportPersistence,
            bookStore: bookStore,
            currentGeneration: fingerprintAccountGeneration,
            isTombstoned: { bookId in
                (try? await syncMetadataStore.isTombstone(entityId: bookId, kind: .book)) ?? false
            },
            events: bookImportEvents,
            onManagedReady: onManagedReady
        )
        let bookFileStorage = BookFileStorage(
            rootURL: documentsURL,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(),
                "epub": EpubCoverExtractor(),
            ],
            metadataExtractors: [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor(),
            ],
            bookIndexingHook: indexingHook,
            isTombstoned: { bookId in
                (try? await syncMetadataStore.isTombstone(entityId: bookId, kind: .book)) ?? false
            },
            fingerprintPersistence: bookImportPersistence,
            fingerprintAccountGeneration: fingerprintAccountGeneration,
            materializationCoordinator: bookMaterializationCoordinator
        )
        let finishDeletedBookCleanup: @Sendable (BookID, UserID, UInt64, @Sendable () async throws -> Void) async throws -> Void = { bookID, ownerID, generation, cleanup in
            try await Self.finishDeletedCleanup(bookID, ownerID: ownerID, generation: generation, cleanup: cleanup,
                books: bookStore, persistence: bookImportPersistence, metadata: syncMetadataStore,
                lifecycle: bookImportLifecycle, userIdBox: userIdBox, currentGeneration: fingerprintAccountGeneration)
        }
        let bookImportRecovery = BookImportRecovery(
            rootURL: documentsURL,
            bookStore: bookStore,
            persistence: bookImportPersistence,
            lifecycle: bookImportLifecycle,
            prepareOwnedSourceCleanup: { token in
                await bookSourceRegistry.prepareOwnedSourceCleanup(for: token)
            },
            isBookTombstoned: { bookID in
                try await syncMetadataStore.isTombstone(entityId: bookID, kind: .book)
            },
            prepareDeletedBookCleanup: { bookID, ownerID in
                guard await userIdBox.value == ownerID,
                      let generation = await fingerprintAccountGeneration() else { throw CancellationError() }
                let cleanup = try await bookFileStorage.prepareDeletionCleanup(bookID: bookID, ownerID: ownerID)
                return {
                    try await finishDeletedBookCleanup(bookID, ownerID, generation, cleanup)
                }
            },
            resume: { book, token in
                _ = try await bookMaterializationCoordinator.resumeRecovered(book: book, token: token)
            },
            resumeRollbackRecovered: { book, token, lease in
                try await bookMaterializationCoordinator.resumeRecovered(
                    book: book, token: token, provisionalRollbackLease: lease
                )
            },
            verifyReadyManagedSource: { book, token in
                guard token.bookID == book.id, token.ownerID == book.userId,
                      await fingerprintAccountGeneration() == token.accountGeneration else { return false }
                do {
                    guard let pending = try await bookImportPersistence.pendingMaterialization(
                        bookID: book.id, ownerID: book.userId
                    ), pending.token == token, pending.phase == .ready,
                    let expected = try await bookImportPersistence.fingerprint(
                        bookID: book.id, ownerID: book.userId
                    ),
                    let managed = try await bookSourceRegistry.managedSource(for: book),
                    let lease = try? await bookSourceRegistry.acquireReadableSource(for: book) else { return false }
                    defer { withExtendedLifetime(lease) {} }
                    let leasedVersion = try CoordinatedSourceProbe.version(
                        at: lease.url, revision: expected.version.materializationRevision
                    )
                    guard case let .managed(leasedBookID, leasedCacheVersion) = lease.cachePolicy,
                          leasedBookID == book.id,
                          leasedCacheVersion == expected.version,
                          lease.url.standardizedFileURL == managed.url.standardizedFileURL,
                          lease.access == .account(managed.readingPermit),
                          managed.fingerprint == expected,
                          leasedVersion == expected.version,
                          await fingerprintAccountGeneration() == token.accountGeneration,
                          let effectAdmission = try? lease.effectAuthority.admit(lease.sourceAccessPermit) else { return false }
                    defer { effectAdmission.release() }
                    return true
                } catch {
                    return false
                }
            }
        )
        if let ownerID = await userIdBox.value,
           let generation = await fingerprintAccountGeneration() {
            Task(priority: .background) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard await userIdBox.value == ownerID,
                      await fingerprintAccountGeneration() == generation,
                      let books = try? await bookStore.books(for: ownerID) else { return }
                for book in books {
                    guard !Task.isCancelled,
                          await userIdBox.value == ownerID,
                          await fingerprintAccountGeneration() == generation,
                          !((try? await syncMetadataStore.isTombstone(entityId: book.id, kind: .book)) ?? false),
                          FileManager.default.fileExists(atPath: bookFileStorage.absoluteFileURL(for: book).path) else { continue }
                    _ = await bookFileStorage.cacheVerifiedManagedFile(for: book)
                }
            }
        }
        return BookDomainResources(bookStore: bookStore, persistence: bookImportPersistence, metadata: syncMetadataStore,
            userIdBox: userIdBox, currentGeneration: fingerprintAccountGeneration, files: bookFileStorage,
            sources: bookSourceRegistry, indexing: indexingHook, lifecycle: bookImportLifecycle,
            events: bookImportEvents, materialization: bookMaterializationCoordinator, recovery: bookImportRecovery)
    }

    static func finishDeletedCleanup(_ bookID: BookID, ownerID: UserID, generation: UInt64,
        cleanup: @Sendable () async throws -> Void, books: any BookStore, persistence: any BookImportPersistence,
        metadata: any SyncMetadataStore, lifecycle: BookImportLifecycle, userIdBox: UserIdBox,
        currentGeneration: @Sendable () async -> UInt64?) async throws {
            guard await userIdBox.value == ownerID,
                  await currentGeneration() == generation,
                  let admission = lifecycle.admitOwnerOperation(ownerID: ownerID, generation: generation) else {
                throw CancellationError()
            }
            defer { admission.release() }
            guard try await metadata.isTombstone(entityId: bookID, kind: .book),
                  try await persistence.isBookPermanentlyDeleted(bookID: bookID, ownerID: ownerID),
                  try await books.book(bookID) == nil,
                  await userIdBox.value == ownerID,
                  await currentGeneration() == generation else { throw CancellationError() }
            try await cleanup()
    }
}

struct BookDomainResources: Sendable {
    let bookStore: any BookStore
    let persistence: any BookImportPersistence
    let metadata: any SyncMetadataStore
    let userIdBox: UserIdBox
    let currentGeneration: @Sendable () async -> UInt64?
    let files: BookFileStorage
    let sources: BookSourceRegistry
    let indexing: RishiSearchIndexingHook
    let lifecycle: BookImportLifecycle
    let events: BookImportEvents
    let materialization: BookMaterializationCoordinator
    let recovery: BookImportRecovery

    /// Finite provenance revalidation for a source captured outside the sync identity gate.
    func validatesManagedSource(book: Book, source: ManagedBookSource) async throws -> Bool {
        let generation = source.accountGeneration
        guard source.bookID == book.id, source.fingerprint.bookID == book.id,
              source.fingerprint.ownerID == book.userId,
              source.readingPermit.ownerID == book.userId,
              await userIdBox.value == book.userId, await currentGeneration() == generation,
              await sources.allowsArtworkRead(for: book, generation: generation),
              let canonical = try await bookStore.book(book.id), canonical.userId == book.userId,
              canonical.fileURL == book.fileURL, canonical.formatType == book.formatType,
              try await persistence.readingPermit(forManagedFingerprint: source.fingerprint,
                  expectedRelativePath: book.fileURL, generation: generation) == source.readingPermit,
              await userIdBox.value == book.userId, await currentGeneration() == generation else { return false }
        return await sources.allowsArtworkRead(for: book, generation: generation)
    }

    func isCurrentAccountPermit(_ permit: AccountMutationPermit) async -> Bool {
        guard await userIdBox.value == permit.ownerID, await currentGeneration() == permit.accountGeneration else { return false }
        return lifecycle.admits(ownerID: permit.ownerID, generation: permit.accountGeneration)
    }
    func admitAccountOperation(_ permit: AccountMutationPermit) async -> BookImportOperationLease? {
        guard await isCurrentAccountPermit(permit), let lease = lifecycle.admitOwnerOperation(ownerID: permit.ownerID, generation: permit.accountGeneration) else { return nil }
        guard await isCurrentAccountPermit(permit) else { lease.release(); return nil }
        return lease
    }
    func abortReplacement(_ token: BookSourceReplacementToken) async {
        let cleanup = Task.detached {
            let permit = AccountMutationPermit(ownerID: token.ownerID, accountGeneration: token.generation)
            do {
                guard let lease = await admitAccountOperation(permit) else { throw CancellationError() }
                defer { lease.release() }
                try await metadata.withLiveBookIdentity(token.bookID) {
                    guard await isCurrentAccountPermit(permit) else { throw CancellationError() }
                    lifecycle.abortBookSourceReplacement(token, restoreSource: true)
                }
            } catch { lifecycle.abortBookSourceReplacement(token, restoreSource: false) }
        }
        await cleanup.value
    }
    func finishDeletedCleanup(_ bookID: BookID, _ ownerID: UserID, _ generation: UInt64, _ cleanup: @Sendable () async throws -> Void) async throws {
        try await BookDomainFactory.finishDeletedCleanup(bookID, ownerID: ownerID, generation: generation, cleanup: cleanup,
            books: bookStore, persistence: persistence, metadata: metadata, lifecycle: lifecycle,
            userIdBox: userIdBox, currentGeneration: currentGeneration)
    }
    func syncAfterBookImported(_ bookID: BookID, engine: SyncEngine, prewarmer: BookPrewarmer) async {
        let markedDirty = await engine.markBookDirty(bookID)
        Task.detached(priority: .userInitiated) {
            guard let book = try? await bookStore.book(bookID), let managed = try? await sources.awaitManagedSource(for: book) else { return }
            await prewarmer.prewarm(book: book, fileURL: managed.url)
        }
        if markedDirty { await engine.requestSync() }
    }
}

