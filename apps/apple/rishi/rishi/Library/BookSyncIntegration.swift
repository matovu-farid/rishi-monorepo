import Foundation

/// One app-side book integration retains the actual immutable resource graph.
/// Inbound sync cannot assemble optional combinations of mutation capabilities.
final class BookSyncIntegration: BookSyncIntegrating {
    private let domain: BookDomainResources
    private let download: BookDownloadCoordinator

    init(domain: BookDomainResources, download: BookDownloadCoordinator) {
        self.domain = domain
        self.download = download
    }

    func currentUserId() async -> UserID? { await domain.userIdBox.value }

    func ensureAccount(_ expectedUserId: UserID?) async throws {
        guard let current = await domain.userIdBox.value,
              expectedUserId == nil || expectedUserId == current else { throw BookSyncAccountChanged() }
    }

    func captureAccountPermit(ownerID: UserID) async throws -> AccountMutationPermit? {
        guard await domain.userIdBox.value == ownerID,
              let generation = await domain.currentGeneration() else { throw BookSyncAccountChanged() }
        return AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
    }

    func ensureCommitAuthority(_ permit: AccountMutationPermit?, expectedUserId: UserID?) async throws {
        try Task.checkCancellation()
        try await ensureAccount(expectedUserId)
        guard let permit, await domain.isCurrentAccountPermit(permit) else { throw BookSyncAccountChanged() }
    }

    func admitCommit(_ permit: AccountMutationPermit?) async throws -> BookImportOperationLease? {
        guard let permit, let admitted = await domain.admitAccountOperation(permit) else { throw BookSyncAccountChanged() }
        return admitted
    }

    func abortSourceReplacement(_ token: BookSourceReplacementToken) async { await domain.abortReplacement(token) }

    func materialize(_ book: Book, r2Key: String?, remoteFile: InboundBookFileMetadata?, permit accountPermit: AccountMutationPermit?) async throws -> VerifiedDownloadedBook? {
        guard let accountPermit else { throw BookSyncAccountChanged() }
        return try await download.downloadAndMaterializeVerified(
            book,
            r2Key: r2Key,
            expectedRemoteSHA256: remoteFile?.sha256,
            expectedRemoteByteCount: remoteFile?.byteCount,
            accountPermit: accountPermit
        )
    }

    func prepareSourceReplacement(_ bookID: BookID, permit: AccountMutationPermit?) async throws -> BookSourceReplacementToken? {
        guard let permit else { throw BookSyncAccountChanged() }
        guard await domain.isCurrentAccountPermit(permit) else { throw CancellationError() }
        let token = try await domain.lifecycle.prepareBookSourceReplacement(
            ownerID: permit.ownerID, generation: permit.accountGeneration, bookID: bookID,
            onFailure: { [domain] token in await domain.abortReplacement(token) }
        )
        guard await domain.isCurrentAccountPermit(permit) else {
            domain.lifecycle.abortBookSourceReplacement(token, restoreSource: false)
            throw CancellationError()
        }
        return token
    }

    func completeSourceReplacement(_ token: BookSourceReplacementToken) async throws {
        let permit = AccountMutationPermit(ownerID: token.ownerID, accountGeneration: token.generation)
        guard await domain.isCurrentAccountPermit(permit),
              domain.lifecycle.completeBookSourceReplacement(token) else {
            throw BookImportPromotionError.retired
        }
    }

    func persistFingerprint(_ fingerprint: BookFileFingerprint, for book: Book, generation capturedGeneration: UInt64?) async -> Bool {
        guard let capturedGeneration else { return false }
        return await domain.files.persistVerifiedFingerprint(fingerprint, for: book, expectedGeneration: capturedGeneration)
    }

    func prepareDeletionCleanup(_ bookID: BookID, ownerID: UserID?, existingBook: Book?) async throws -> (@Sendable () async throws -> Void)? {
        guard let ownerID else { throw BookSyncAccountChanged() }
        return try await domain.files.prepareDeletionCleanup(bookID: bookID, ownerID: ownerID)
    }

    func withDeletionAdmission(ownerID: UserID?, operation: @Sendable (UInt64?) async throws -> Void) async throws {
        guard let ownerID else { throw BookSyncAccountChanged() }
        guard await domain.userIdBox.value == ownerID,
              let generation = await domain.currentGeneration(),
              let lease = domain.lifecycle.admitOwnerOperation(ownerID: ownerID, generation: generation) else {
            throw CancellationError()
        }
        defer { lease.release() }
        guard await domain.userIdBox.value == ownerID,
              await domain.currentGeneration() == generation else {
            throw CancellationError()
        }
        try await operation(generation)
        guard await domain.userIdBox.value == ownerID,
              await domain.currentGeneration() == generation else {
            throw CancellationError()
        }
    }

    func restoreAfterFailedRetirement(_ book: Book, generation: UInt64?) async -> Bool {
        await domain.materialization.restoreBookAfterFailedRetirement(
            book: book,
            expectedGeneration: generation
        )
    }

    func scheduleRecovery(ownerID: UserID, generation: UInt64) async {
        Task { [domain] in
            _ = try? await domain.recovery.recover(ownerID: ownerID, generation: generation) {
                let currentOwner = await domain.userIdBox.value
                let currentGeneration = await domain.currentGeneration()
                return currentOwner == ownerID && currentGeneration == generation
            }
        }
    }

    func retireBookForDeletion(_ bookID: BookID, ownerID: UserID?, generation: UInt64?) async throws -> BookDeletionRetirementWitness? {
        guard let ownerID, let generation else { throw BookSyncAccountChanged() }
        let permit = AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
        guard await domain.isCurrentAccountPermit(permit) else { throw CancellationError() }
        return domain.lifecycle.retireBookForNonLocalDeletion(
            ownerID: permit.ownerID, generation: permit.accountGeneration, bookID: bookID
        )
    }

    func deferDeletionCleanup(_ witness: BookDeletionRetirementWitness, cleanup: @escaping @Sendable () async throws -> Void) {
        Task.detached(priority: .utility) { [domain] in
            await domain.lifecycle.waitForRetiredBookDeletion(witness: witness)
            do {
                try await domain.finishDeletedCleanup(witness.bookID, witness.ownerID, witness.generation, cleanup)
            } catch {
                Log.error("book.deletion.cleanup_failed", error: error)
            }
        }
    }

    func activateBook(_ bookID: BookID, permit: AccountMutationPermit?) async {
        guard let permit else { return }
        guard await domain.isCurrentAccountPermit(permit) else { return }
        _ = domain.sources.advanceBookAttemptSynchronously(ownerID: permit.ownerID, generation: permit.accountGeneration, bookID: bookID)
    }

    func managedFingerprint(_ book: Book) async -> BookFileFingerprint? {
        return try? await domain.sources.managedSource(for: book)?.fingerprint
    }

    func readingPermit(_ book: Book) async -> BookReadingPermit? {
        guard let generation = await domain.currentGeneration() else { return nil }
        return try? await domain.persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: generation)
    }

    func contentDigest(_ book: Book, fallbackFingerprint: BookFileFingerprint?) async -> String? {
        if let fingerprint = try? await domain.persistence.fingerprint(bookID: book.id, ownerID: book.userId) {
            return fingerprint.sha256
        }
        if let pending = try? await domain.persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) {
            return pending.expectedSHA256
        }
        return nil
    }

    func hasPendingMaterialization(_ book: Book) async -> Bool {
        return (try? await domain.persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)) != nil
    }

    func persistAcceptance(_ acceptance: BookServerAcceptance, permit: BookReadingPermit, fingerprint: BookFileFingerprint) async -> Bool {
        return (try? await domain.persistence.recordServerAcceptance(
            permit: permit,
            expectedFingerprint: fingerprint,
            acceptance: acceptance
        )) == true
    }

    func persistAcceptance(_ acceptance: BookServerAcceptance, permit accountPermit: AccountMutationPermit, fingerprint: BookFileFingerprint) async -> Bool {
        return (try? await domain.persistence.recordServerAcceptance(
            accountPermit: accountPermit,
            expectedFingerprint: fingerprint,
            acceptance: acceptance
        )) == true
    }
}
