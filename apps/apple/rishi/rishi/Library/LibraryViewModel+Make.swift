import Foundation


extension LibraryViewModel {
    @MainActor
    static func make(
        bookStore: any BookStore,
        userId: UserID,
        importCoordinator: ImportCoordinator,
        positionStore: any PositionStore,
        bookFileStorage: BookFileStorage,
        bookSourceRegistry: BookSourceRegistry? = nil,
        bookImportLifecycle: BookImportLifecycle? = nil,
        bookMaterializationCoordinator: BookMaterializationCoordinator? = nil,
        bookImportRecovery: BookImportRecovery? = nil,
        bookImportEvents: BookImportEvents? = nil,
        currentAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        accountIdentity: LibraryAccountIdentity? = nil,
        currentAccountIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil },
        onBookDeleted: (@Sendable (BookID) async throws -> Void)? = nil,
        syncEngine: SyncEngine? = nil
    ) -> LibraryViewModel {
        let registrationValidator: (@Sendable (BookImportEvent) async -> Bool)?
        if let bookMaterializationCoordinator {
            registrationValidator = { event in
                await bookMaterializationCoordinator.validatesRegistrationEvent(event)
            }
        } else {
            registrationValidator = nil
        }
        let logicalDeletion: (@Sendable (Book, BookDeletionRetirementWitness?) async throws -> DeletionCommitOutcome)?
        if let syncEngine, let bookImportLifecycle {
            logicalDeletion = { book, suppliedWitness in
                guard let witness = suppliedWitness, witness.ownerID == book.userId, witness.bookID == book.id,
                      await currentAccountGeneration() == witness.generation,
                      let operation = bookImportLifecycle.admitOwnerOperation(ownerID: witness.ownerID, generation: witness.generation) else {
                    throw LibraryDeletionLifecycleError.accountChanged
                }
                defer { operation.release() }
                let cleanup = try await bookFileStorage.prepareDeletionCleanup(bookID: book.id, ownerID: book.userId)
                let permit = AccountMutationPermit(ownerID: book.userId, accountGeneration: witness.generation)
                let canonicalMutation: @Sendable () async throws -> Void = {
                    guard await currentAccountGeneration() == witness.generation,
                          try await bookStore.deletePermanentlyIfUnchanged(book.id, matching: book, accountPermit: permit) else {
                        throw LibraryDeletionLifecycleError.canonicalChanged
                    }
                }
                let deferredCleanup: @Sendable () async -> Void = {
                    Log.event("library.delete.cleanup_started", data: ["book_id": book.id.uuidString])
                    await bookImportLifecycle.waitForRetiredBookDeletion(witness: witness)
                    guard await currentAccountGeneration() == witness.generation,
                          let cleanupOperation = bookImportLifecycle.admitOwnerOperation(ownerID: book.userId, generation: witness.generation) else { return }
                    defer { cleanupOperation.release() }
                    do {
                        guard try await syncEngine.isBookDeleted(book.id),
                              try await bookStore.book(book.id) == nil,
                              try await bookFileStorage.isPermanentlyDeleted(bookID: book.id, ownerID: book.userId),
                              await currentAccountGeneration() == witness.generation else { return }
                        try await cleanup()
                        Log.event("library.delete.cleanup_finished", data: ["book_id": book.id.uuidString])
                    } catch { Log.error("library.delete.cleanup_failed", error: error) }
                }
                do {
                    try await syncEngine.markBookDeleted(book.id, canonicalMutation: canonicalMutation)
                    Log.event("library.delete.logical_committed", data: ["book_id": book.id.uuidString])
                    return .committed(deferredCleanup: deferredCleanup)
                } catch SyncMetadataError.savedBookTombstone {
                    Log.event("library.delete.logical_committed", data: ["book_id": book.id.uuidString, "canonical_pending": "true"])
                    let reconcile: @Sendable () async -> Bool = {
                        guard await currentAccountGeneration() == witness.generation,
                              let retryOperation = bookImportLifecycle.admitOwnerOperation(ownerID: book.userId, generation: witness.generation) else { return false }
                        defer { retryOperation.release() }
                        do {
                            guard try await syncEngine.isBookDeleted(book.id) else { return false }
                            let current = try await bookStore.book(book.id)
                            guard current == nil || (current?.userId == book.userId && current?.fileURL == book.fileURL) else { return false }
                            try await syncEngine.markBookDeleted(book.id, canonicalMutation: {
                                guard try await bookStore.deletePermanentlyIfUnchanged(book.id, matching: current, accountPermit: permit) else {
                                    throw LibraryDeletionLifecycleError.canonicalChanged
                                }
                            })
                            return true
                        } catch { Log.error("library.delete.reconcile_failed", error: error); return false }
                    }
                    return .savedNeedsReconciliation(reconcile: reconcile, deferredCleanup: deferredCleanup)
                }
            }
        } else { logicalDeletion = nil }
        let tombstoneLookup: (@Sendable (BookID) async throws -> Bool)? = syncEngine.map { engine in
            { @Sendable id in try await engine.isBookDeleted(id) }
        }
        return LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            boundAccountIdentity: accountIdentity,
            currentAccountIdentity: currentAccountIdentity,
            importCoordinator: importCoordinator,
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(
                storage: bookFileStorage,
                isManagedReady: { book in
                    guard let bookSourceRegistry else { return true }
                    return (try? await bookSourceRegistry.managedSource(for: book)) != nil
                },
                isArtworkReadAllowed: { book in
                    guard book.userId == userId else { return false }
                    guard let bookSourceRegistry else { return true }
                    guard let boundGeneration = accountIdentity?.generation,
                          await currentAccountGeneration() == boundGeneration,
                          await bookSourceRegistry.allowsArtworkRead(for: book, generation: boundGeneration)
                    else { return false }
                    return true
                }
            ),
            deleteBook: { book in try await bookFileStorage.delete(book) },
            beforeBookDeleted: { book in
                guard let bookImportLifecycle else { return nil }
                guard let generation = await currentAccountGeneration() else {
                    throw LibraryDeletionLifecycleError.accountGenerationUnavailable
                }
                if let accountIdentity, generation != accountIdentity.generation {
                    throw LibraryDeletionLifecycleError.accountChanged
                }
                let deletionGeneration = accountIdentity?.generation ?? generation
                let witness: BookDeletionRetirementWitness
                if syncEngine != nil {
                    witness = bookImportLifecycle.retireBookForDeletion(ownerID: book.userId, generation: deletionGeneration, bookID: book.id)
                } else {
                    witness = await bookImportLifecycle.drainBookForDeletion(ownerID: book.userId, generation: deletionGeneration, bookID: book.id)
                }
                guard await currentAccountGeneration() == generation else {
                    throw LibraryDeletionLifecycleError.accountChanged
                }
                return witness
            },
            restoreBookAfterFailedRetirement: { book, witness in
                guard let bookMaterializationCoordinator else { return .refused }
                return await bookMaterializationCoordinator.restoreBookAfterFailedRetirement(
                    book: book,
                    witness: witness,
                    expectedGeneration: accountIdentity?.generation,
                    recoverStartedSampleRepair: { book, token, lease in
                        guard let bookImportRecovery else { return .refused }
                        return await bookImportRecovery.recoverBook(
                            book: book,
                            expectedToken: token,
                            rollbackLease: lease,
                            isCurrentIdentity: {
                                await currentAccountGeneration() == lease.witness.generation
                            }
                        )
                    }
                )
            },
            onBookDeleted: onBookDeleted,
            logicalBookDeletion: logicalDeletion,
            isBookTombstoned: tombstoneLookup,
            bookImportEvents: bookImportEvents,
            currentAccountGeneration: currentAccountGeneration,
            validatesRegistrationEvent: registrationValidator
        )
    }
}

private enum LibraryDeletionLifecycleError: Error {
    case accountGenerationUnavailable
    case accountChanged
    case canonicalChanged
}
