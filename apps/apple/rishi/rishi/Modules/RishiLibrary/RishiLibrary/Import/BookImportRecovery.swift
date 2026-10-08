import CryptoKit
import Foundation

/// Re-adopts interrupted imports only after the prior account generation has
/// been fenced and drained. The caller must pass the identity and generation
/// that its authenticated session currently owns.
public struct BookImportRecovery: Sendable {
    private enum ArtifactVerification {
        case verified(VerifiedBookArtifacts)
        case invalid
        case retryable
    }

    private enum RollbackDestinationCheck: Equatable {
        case absent
        case exact
        case conflict
        case retryable
    }

    public enum RecoveryError: Error, Sendable, Equatable {
        case retryableWorkRemains
    }
    private let rootURL: URL
    private let bookStore: any BookStore
    private let persistence: any BookImportPersistence
    private let lifecycle: BookImportLifecycle
    private let fileVersionInspector: any ManagedFileVersionInspecting
    private let resumeRecovered: @Sendable (Book, BookMaterializationToken) async throws -> Void
    private let resumeRollbackRecovered: @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async throws -> BookFileFingerprint
    private let verifyReadyManagedSource: @Sendable (Book, BookMaterializationToken) async -> Bool
    private let prepareOwnedSourceCleanup: (@Sendable (BookMaterializationToken) async -> Bool)?
    private let isBookTombstoned: (@Sendable (BookID) async throws -> Bool)?
    private let prepareDeletedBookCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))?

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        persistence: any BookImportPersistence,
        lifecycle: BookImportLifecycle,
        fileVersionInspector: any ManagedFileVersionInspecting = FileManagedFileVersionInspector(),
        prepareOwnedSourceCleanup: (@Sendable (BookMaterializationToken) async -> Bool)? = nil,
        isBookTombstoned: (@Sendable (BookID) async throws -> Bool)? = nil,
        prepareDeletedBookCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))? = nil,
        resume: @escaping @Sendable (Book, BookMaterializationToken) async throws -> Void = { _, _ in },
        resumeRollbackRecovered: @escaping @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async throws -> BookFileFingerprint = { _, _, _ in throw RecoveryError.retryableWorkRemains },
        verifyReadyManagedSource: @escaping @Sendable (Book, BookMaterializationToken) async -> Bool = { _, _ in false }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.bookStore = bookStore
        self.persistence = persistence
        self.lifecycle = lifecycle
        self.fileVersionInspector = fileVersionInspector
        self.prepareOwnedSourceCleanup = prepareOwnedSourceCleanup
        self.isBookTombstoned = isBookTombstoned
        self.prepareDeletedBookCleanup = prepareDeletedBookCleanup
        self.resumeRecovered = resume
        self.resumeRollbackRecovered = resumeRollbackRecovered
        self.verifyReadyManagedSource = verifyReadyManagedSource
    }

    /// Recovers one sample-repair attempt under the provisional lease created
    /// for a failed local deletion. This intentionally avoids the account-wide
    /// scan: every read, adoption and result belongs to this exact Book/token.
    public func recoverBook(
        book: Book,
        expectedToken: BookMaterializationToken,
        rollbackLease: BookImportProvisionalRollbackLease,
        isCurrentIdentity: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) async -> BookDeletionRollbackResult {
        let witness = rollbackLease.witness
        guard !Task.isCancelled,
              expectedToken.ownerID == book.userId,
              expectedToken.bookID == book.id,
              expectedToken.accountGeneration == witness.generation,
              witness.ownerID == book.userId,
              witness.bookID == book.id,
              lifecycle.isCurrentProvisionalDeletionRollbackLease(rollbackLease),
              await isCurrentIdentity(),
              !Task.isCancelled,
              lifecycle.isCurrentProvisionalDeletionRollbackLease(rollbackLease) else {
            return .refused
        }

        guard let claim = lifecycle.claimBookRecovery(
            ownerID: book.userId,
            generation: witness.generation,
            bookID: book.id,
            expectedToken: expectedToken,
            provisionalRollbackLease: rollbackLease
        ) else {
            return .refused
        }
        defer { claim.release() }

        guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let initialBook = try? await bookStore.book(book.id), initialBook == book,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let initialJob = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
              ),
              initialJob.token == expectedToken,
              initialJob.sourceKind == .sampleRepair,
              (initialJob.phase == .ready || Self.isRollbackStagedSampleRepair(initialJob)),
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              (try? await persistence.readingPermit(
                bookID: book.id, ownerID: book.userId, generation: witness.generation
              )) != nil,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }

        guard !Task.isCancelled else { return .refused }
        await claim.drainPriorAttempt()
        guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let currentBook = try? await bookStore.book(book.id), currentBook == book,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let job = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
              ),
              job.token == expectedToken, job.sourceKind == .sampleRepair,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              (try? await persistence.readingPermit(
                bookID: book.id, ownerID: book.userId, generation: witness.generation
              )) != nil,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }

        // A prior rollback may have committed the managed file immediately
        // before cancellation prevented lifecycle finalization. Accept that
        // exact ready attempt on a same-witness retry without adopting it.
        if job.phase == .ready {
            guard !Task.isCancelled else { return .refused }
            guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  let readyBook = try? await bookStore.book(book.id), readyBook == book,
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  let readyJob = try? await persistence.pendingMaterializationForRecovery(
                    bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
                  ), readyJob.token == expectedToken, readyJob.sourceKind == .sampleRepair,
                  readyJob.phase == .ready,
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  let fingerprint = try? await persistence.fingerprint(bookID: book.id, ownerID: book.userId),
                  Self.readyFingerprint(fingerprint, matches: readyJob, book: book),
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  (try? await persistence.readingPermit(
                    forManagedFingerprint: fingerprint,
                    expectedRelativePath: book.fileURL,
                    generation: witness.generation
                  )) != nil,
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  await verifyReadyManagedSource(book, expectedToken),
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  !Task.isCancelled else {
                return .refused
            }
            return .ready(expectedToken)
        }
        guard Self.isRollbackStagedSampleRepair(job) else { return .refused }

        // An extant destination without this attempt's exact promotion
        // provenance is a conflict. Preserve both it and staged provenance.
        guard !Task.isCancelled else { return .refused }
        switch rollbackDestinationCheck(job) {
        case .absent, .exact:
            break
        case .conflict:
            return .conflict(expectedToken)
        case .retryable:
            return .refused
        }

        let artifacts: VerifiedBookArtifacts
        switch verify(job: job) {
        case let .verified(value):
            artifacts = value
        case .retryable:
            return .refused
        case .invalid:
            guard rollbackDestinationCheck(job) == .absent else {
                return .refused
            }
            guard !Task.isCancelled else {
                return .refused
            }
            guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
                return .refused
            }
            guard let priorFingerprint = try? await persistence.sampleRepairFingerprint(bookID: book.id, ownerID: book.userId) else {
                return .refused
            }
            guard Self.sampleFingerprint(priorFingerprint, matches: job, book: book) else {
                return .refused
            }
            guard !Task.isCancelled else {
                return .refused
            }
            guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
                return .refused
            }
            guard !Task.isCancelled else {
                return .refused
            }
            guard let quarantined = try? await persistence.quarantineRecovery(
                    expectedToken: expectedToken,
                    currentOwnerID: book.userId,
                    currentGeneration: witness.generation,
                    newAttemptID: UUID()
                  ) else {
                return .refused
            }
            // Record an already-committed database token rotation synchronously,
            // even if cancellation arrived while the persistence call suspended.
            guard claim.recordDatabaseSuccessor(quarantined, lease: rollbackLease) else {
                return .refused
            }
            guard quarantined.ownerID == book.userId,
                  quarantined.accountGeneration == witness.generation,
                  quarantined.bookID == book.id,
                  quarantined.attemptID != expectedToken.attemptID,
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  let paused = try? await persistence.pendingMaterializationForRecovery(
                    bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
                  ), paused.token == quarantined, paused.phase == .paused,
                  paused.sourceKind == .sampleRepair,
                  await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  let repairFingerprint = try? await persistence.sampleRepairFingerprint(
                    bookID: book.id, ownerID: book.userId
                  ), repairFingerprint == priorFingerprint,
                  Self.sampleFingerprint(repairFingerprint, matches: job, book: book),
                  await hasRollbackAuthority(book: book, token: quarantined, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
                  !Task.isCancelled,
                  claim.allowMaterialization(quarantined),
                  claim.recordPausedAttempt(quarantined, lease: rollbackLease),
                  let failurePermit = claim.sourceFailurePermit(for: quarantined),
                  await hasRollbackAuthority(book: book, token: quarantined, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
                return .refused
            }
            _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
            guard !Task.isCancelled,
                  await hasRollbackAuthority(book: book, token: quarantined, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
                return .refused
            }
            Self.removeRetiredPartialIfSafe(
                relativePath: job.stagingRelativePath,
                retiredAttemptID: expectedToken.attemptID,
                rootURL: rootURL
            )
            return .retryablePaused(quarantined)
        }

        guard await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let freshBook = try? await bookStore.book(book.id), freshBook == book,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let freshJob = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
              ), freshJob.token == expectedToken, freshJob.sourceKind == .sampleRepair,
              freshJob.phase == job.phase,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }

        let attemptID = UUID()
        guard !Task.isCancelled,
              await hasRollbackAuthority(book: book, token: expectedToken, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }
        guard let adopted = try? await persistence.adoptRecovery(
            expectedToken: expectedToken,
            currentOwnerID: book.userId,
            currentGeneration: witness.generation,
            newAttemptID: attemptID,
            verifiedArtifacts: artifacts
        ) else {
            return .refused
        }
        // The persistence CAS has already installed this exact successor.
        // Record it before checking cancellation or awaiting any follow-up.
        guard claim.recordDatabaseSuccessor(adopted, lease: rollbackLease) else {
            return .refused
        }
        guard adopted.ownerID == book.userId,
              adopted.accountGeneration == witness.generation,
              adopted.bookID == book.id,
              adopted.attemptID == attemptID,
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let adoptedJob = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
              ), adoptedJob.token == adopted,
              adoptedJob.sourceKind == .sampleRepair,
              adoptedJob.phase != .ready,
              adoptedJob.phase != .failed,
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              adoptedJob.phase != .cancelled else {
            return .refused
        }

        guard claim.allowMaterialization(adopted),
              !Task.isCancelled,
              lifecycle.activatePromotionAttempt(adopted, provisionalRollbackLease: rollbackLease),
              let failurePermit = claim.sourceFailurePermit(for: adopted),
              !Task.isCancelled,
              let admission = claim.promoteMaterialization(adopted) else {
            return .refused
        }
        defer { admission.release() }
        guard await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }

        let committedFingerprint: BookFileFingerprint
        do {
            guard !Task.isCancelled,
                  await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
                return .refused
            }
            committedFingerprint = try await resumeRollbackRecovered(book, adopted, rollbackLease)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return .refused }
            if lifecycle.isCurrentProvisionalDeletionRollbackLease(rollbackLease) {
                _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
            }
            return .refused
        }
        guard await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let finalBook = try? await bookStore.book(book.id), finalBook == book,
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let finalJob = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id, ownerID: book.userId, currentGeneration: witness.generation
              ), finalJob.token == adopted, finalJob.sourceKind == .sampleRepair,
              finalJob.phase == .ready,
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              let finalFingerprint = try? await persistence.fingerprint(bookID: book.id, ownerID: book.userId),
              finalFingerprint == committedFingerprint,
              Self.readyFingerprint(finalFingerprint, matches: finalJob, book: book),
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              (try? await persistence.readingPermit(
                forManagedFingerprint: finalFingerprint,
                expectedRelativePath: book.fileURL,
                generation: witness.generation
              )) != nil,
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity),
              await verifyReadyManagedSource(book, adopted),
              await hasRollbackAuthority(book: book, token: adopted, lease: rollbackLease, isCurrentIdentity: isCurrentIdentity) else {
            return .refused
        }
        guard !Task.isCancelled else {
            return .refused
        }
        return .ready(adopted)
    }

    private func hasRollbackAuthority(
        book: Book,
        token: BookMaterializationToken,
        lease: BookImportProvisionalRollbackLease,
        isCurrentIdentity: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        guard token.ownerID == book.userId,
              token.bookID == book.id,
              token.accountGeneration == lease.witness.generation,
              !Task.isCancelled,
              await isCurrentIdentity() else { return false }
        return !Task.isCancelled && lifecycle.isCurrentProvisionalDeletionRollbackLease(lease)
    }

    private static func sampleFingerprint(
        _ fingerprint: BookFileFingerprint?,
        matches job: PendingBookMaterialization,
        book: Book
    ) -> Bool {
        guard let fingerprint else { return false }
        return fingerprint.bookID == book.id
            && fingerprint.ownerID == book.userId
            && fingerprint.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame
            && fingerprint.version.byteCount == job.expectedByteCount
            && job.destinationRelativePath == book.fileURL
    }

    private static func isRollbackStagedSampleRepair(_ job: PendingBookMaterialization) -> Bool {
        guard job.sourceKind == .sampleRepair else { return false }
        switch job.phase {
        case .prepared, .promoting, .promoted:
            return true
        case .paused:
            return job.preparedFileIdentifier != nil
        case .registered, .copying, .ready, .failed, .cancelled:
            return false
        }
    }

    private static func readyFingerprint(
        _ fingerprint: BookFileFingerprint,
        matches job: PendingBookMaterialization,
        book: Book
    ) -> Bool {
        fingerprint.bookID == book.id
            && fingerprint.ownerID == book.userId
            && fingerprint.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame
            && fingerprint.version.byteCount == job.expectedByteCount
            && fingerprint.version.fileIdentifier == job.destinationFileIdentifier
            && fingerprint.version.materializationRevision == job.promotionRevision
            && job.destinationRelativePath == book.fileURL
    }

    private func rollbackDestinationCheck(_ job: PendingBookMaterialization) -> RollbackDestinationCheck {
        guard let destinationURL = Self.containedURL(job.destinationRelativePath, rootURL: rootURL) else { return .conflict }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else { return .absent }
        let expectedIdentifier = job.destinationFileIdentifier
            ?? ((job.phase == .promoting || job.phase == .promoted || job.promotionRevision != nil)
                ? job.preparedFileIdentifier : nil)
        guard let expectedIdentifier, let revision = job.promotionRevision else { return .conflict }
        let version: ManagedFileVersion?
        do {
            version = try fileVersionInspector.managedFileVersion(
                at: destinationURL, materializationRevision: revision
            )
        } catch {
            return .retryable
        }
        guard let version else { return .retryable }
        guard version.fileIdentifier == expectedIdentifier,
              version.materializationRevision == revision,
              version.byteCount == job.expectedByteCount else { return .conflict }
        let digest: (sha256: String, count: Int64)
        do {
            digest = try Self.digestAndCount(destinationURL)
        } catch {
            return .retryable
        }
        guard digest.count == job.expectedByteCount,
              digest.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame else { return .conflict }
        return .exact
    }

    /// Returns fresh attempt tokens for verified jobs. Jobs owned by another
    /// user, with incomplete provenance, or with changed artifacts are left
    /// untouched for the normal retry or quarantine path.
    public func recover(
        ownerID: UserID,
        generation: UInt64,
        isCurrentIdentity: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) async throws -> [BookMaterializationToken] {
        try await reconcileCommittedDeletions(ownerID: ownerID, generation: generation, isCurrentIdentity: isCurrentIdentity)
        let ownedBooks = try await bookStore.books(for: ownerID).filter { $0.userId == ownerID }
        await cleanupReadyOwnedSources(books: ownedBooks, ownerID: ownerID, generation: generation)
        var candidates: [BookID: BookMaterializationToken] = [:]
        var recoveryClaims: [BookID: BookImportRecoveryClaim] = [:]
        var candidateBooks: [BookID: Book] = [:]
        var unresolvedClaimBookIDs = Set<BookID>()
        var failureTokens: [BookID: BookMaterializationToken] = [:]
        var failurePermits: [BookID: BookImportRecoverySourceFailurePermit] = [:]
        var hasRetryableWork = false
        guard await isCurrentIdentity() else { return [] }
        do {
            for book in ownedBooks {
                guard let job = try await persistence.pendingMaterializationForRecovery(
                    bookID: book.id,
                    ownerID: ownerID,
                    currentGeneration: generation
                ),
                      job.token.ownerID == ownerID,
                      job.token.bookID == book.id,
                      job.phase != .ready,
                      job.phase != .failed,
                      job.phase != .cancelled else { continue }
                if Self.isWaitingForPicker(job) {
                    guard let currentToken = try await persistence.reauthorizeWaitingRecovery(
                        expectedToken: job.token,
                        currentOwnerID: ownerID,
                        currentGeneration: generation
                    ), currentToken.ownerID == ownerID,
                       currentToken.accountGeneration == generation,
                       currentToken.bookID == book.id,
                       currentToken.attemptID == job.token.attemptID else {
                        hasRetryableWork = true
                        continue
                    }
                    continue
                }
                guard let claim = lifecycle.claimBookRecovery(ownerID: ownerID, generation: generation, bookID: book.id, expectedToken: job.token) else {
                    // A live materialization or another recovery owns this book;
                    // leave it alone so this scan cannot retire user work, and
                    // keep recovery incomplete for a later scan.
                    hasRetryableWork = true
                    continue
                }
                candidates[book.id] = job.token
                candidateBooks[book.id] = book
                recoveryClaims[book.id] = claim
                unresolvedClaimBookIDs.insert(book.id)
                failureTokens[book.id] = job.token
            }
        } catch {
            await failUnresolvedRecoveryWaiters(
                claimBookIDs: unresolvedClaimBookIDs,
                claims: recoveryClaims,
                books: candidateBooks,
                tokens: failureTokens,
                permits: failurePermits
            )
            throw error
        }

        // Ordinary service resolution has no recovery work to perform. In
        // particular, do not fence owner admission or disturb live readers.
        guard !candidates.isEmpty else {
            if hasRetryableWork { throw RecoveryError.retryableWorkRemains }
            return []
        }
        for (bookID, _) in candidates.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            await recoveryClaims[bookID]?.drainPriorAttempt()
        }
        guard await isCurrentIdentity() else {
            await failUnresolvedRecoveryWaiters(claimBookIDs: unresolvedClaimBookIDs, claims: recoveryClaims, books: candidateBooks, tokens: failureTokens, permits: failurePermits)
            return []
        }

        var recovered: [BookMaterializationToken] = []
        for (bookID, expectedToken) in candidates.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let recoveryClaim = recoveryClaims[bookID] else { continue }
            defer { recoveryClaim.release() }
            do {
                guard let book = try await bookStore.book(bookID), book.userId == ownerID,
                      let job = try await persistence.pendingMaterializationForRecovery(
                        bookID: bookID,
                        ownerID: ownerID,
                        currentGeneration: generation
                      ),
                      job.token == expectedToken,
                      job.token.ownerID == ownerID,
                      job.token.bookID == bookID,
                      job.phase != .ready,
                      job.phase != .failed,
                      job.phase != .cancelled,
                      !Self.isWaitingForPicker(job) else {
                    if let expectedBook = candidateBooks[bookID] {
                        await failRecoveryWaiters(recoveryClaim, token: expectedToken, book: expectedBook)
                    }
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                guard await isCurrentIdentity() else {
                    await failUnresolvedRecoveryWaiters(claimBookIDs: unresolvedClaimBookIDs, claims: recoveryClaims, books: candidateBooks, tokens: failureTokens, permits: failurePermits)
                    return recovered
                }
                let artifacts: VerifiedBookArtifacts
                switch verify(job: job) {
                case let .verified(value): artifacts = value
                case .retryable:
                    hasRetryableWork = true
                    await failRecoveryWaiters(recoveryClaim, token: expectedToken, book: book)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                case .invalid:
                    let retiredStagingPath = job.stagingRelativePath
                    let quarantined = try await persistence.quarantineRecovery(
                        expectedToken: job.token,
                        currentOwnerID: ownerID,
                        currentGeneration: generation,
                        newAttemptID: UUID()
                    )
                    if let quarantined,
                       quarantined.ownerID == ownerID,
                       quarantined.accountGeneration == generation,
                       quarantined.bookID == bookID,
                       quarantined.attemptID != expectedToken.attemptID,
                       let quarantinedJob = try await persistence.pendingMaterializationForRecovery(
                           bookID: bookID, ownerID: ownerID, currentGeneration: generation
                       ), quarantinedJob.token == quarantined,
                       quarantinedJob.phase == .paused,
                       quarantinedJob.retryableErrorCode == "recovery_artifact_invalid",
                       recoveryClaim.allowMaterialization(quarantined) {
                        Self.removeRetiredPartialIfSafe(
                            relativePath: retiredStagingPath,
                            retiredAttemptID: expectedToken.attemptID,
                            rootURL: rootURL
                        )
                        if !lifecycle.activatePromotionAttempt(quarantined) { hasRetryableWork = true }
                        if let permit = recoveryClaim.sourceFailurePermit(for: quarantined) {
                            failureTokens[bookID] = quarantined
                            failurePermits[bookID] = permit
                            _ = await lifecycle.failPendingBookSource(book: book, permit: permit)
                        }
                        unresolvedClaimBookIDs.remove(bookID)
                    } else {
                        hasRetryableWork = true
                        await failRecoveryWaiters(recoveryClaim, token: expectedToken, book: book)
                        unresolvedClaimBookIDs.remove(bookID)
                    }
                    // A successful quarantine is durable and authorizes picker
                    // retry; later scans skip its persisted waiting-for-picker
                    // state instead of rotating it indefinitely.
                    continue
                }
                let retiredStagingPath = job.stagingRelativePath
                let retiredAttemptWasUnprepared = [.registered, .copying, .paused].contains(job.phase)
                    && job.preparedFileIdentifier == nil
                    && job.destinationFileIdentifier == nil
                    && job.promotionRevision == nil
                let attemptID = UUID()
                guard let token = try await persistence.adoptRecovery(
                    expectedToken: job.token,
                    currentOwnerID: ownerID,
                    currentGeneration: generation,
                    newAttemptID: attemptID,
                    verifiedArtifacts: artifacts
                ), token.ownerID == ownerID, token.accountGeneration == generation,
                   token.bookID == bookID, token.attemptID == attemptID,
                   let adoptedJob = try await persistence.pendingMaterializationForRecovery(
                       bookID: bookID, ownerID: ownerID, currentGeneration: generation
                   ), adoptedJob.token == token,
                   adoptedJob.phase != .ready, adoptedJob.phase != .failed, adoptedJob.phase != .cancelled,
                   !Self.isWaitingForPicker(adoptedJob) else {
                    hasRetryableWork = true
                    if job.phase != .paused {
                        _ = try? await persistence.transition(token: job.token, from: job.phase, to: .paused)
                    }
                    await failRecoveryWaiters(recoveryClaim, token: expectedToken, book: book)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                if retiredAttemptWasUnprepared {
                    Self.removeRetiredPartialIfSafe(
                        relativePath: retiredStagingPath,
                        retiredAttemptID: expectedToken.attemptID,
                        rootURL: rootURL
                    )
                }
                guard recoveryClaim.allowMaterialization(token) else {
                    hasRetryableWork = true
                    await failRecoveryWaiters(recoveryClaim, token: expectedToken, book: book)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                failureTokens[bookID] = token
                guard lifecycle.activatePromotionAttempt(token) else {
                    hasRetryableWork = true
                    await failRecoveryWaiters(recoveryClaim, token: token, book: book)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                guard let failurePermit = recoveryClaim.sourceFailurePermit(for: token) else {
                    hasRetryableWork = true
                    await failRecoveryWaiters(recoveryClaim, token: token, book: book)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                failurePermits[bookID] = failurePermit
                guard let activeAttempt = recoveryClaim.promoteMaterialization(token) else {
                    hasRetryableWork = true
                    _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
                    unresolvedClaimBookIDs.remove(bookID)
                    continue
                }
                defer { activeAttempt.release() }
                guard await isCurrentIdentity() else {
                    await pauseAdoptedAttempt(token)
                    _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
                    unresolvedClaimBookIDs.remove(bookID)
                    await failUnresolvedRecoveryWaiters(claimBookIDs: unresolvedClaimBookIDs, claims: recoveryClaims, books: candidateBooks, tokens: failureTokens, permits: failurePermits)
                    return recovered
                }
                var resumed = false
                do {
                    try await resumeRecovered(book, token)
                    resumed = true
                    await cleanupReadyOwnedSources(books: [book], ownerID: ownerID, generation: generation)
                } catch {
                    await pauseAdoptedAttempt(token)
                    _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
                    hasRetryableWork = true
                    unresolvedClaimBookIDs.remove(bookID)
                }
                if resumed {
                    recovered.append(token)
                    unresolvedClaimBookIDs.remove(bookID)
                }
            } catch {
                await failUnresolvedRecoveryWaiters(claimBookIDs: unresolvedClaimBookIDs, claims: recoveryClaims, books: candidateBooks, tokens: failureTokens, permits: failurePermits)
                throw error
            }
        }
        if hasRetryableWork {
            await failUnresolvedRecoveryWaiters(claimBookIDs: unresolvedClaimBookIDs, claims: recoveryClaims, books: candidateBooks, tokens: failureTokens, permits: failurePermits)
            throw RecoveryError.retryableWorkRemains
        }
        return recovered
    }

    /// The sync tombstone is the crash journal across the two stores. Reconcile
    /// its canonical rows without waiting on old file owners; cleanup owns the
    /// original persisted attempt and runs independently afterward.
    private func reconcileCommittedDeletions(ownerID: UserID, generation: UInt64, isCurrentIdentity: @escaping @MainActor @Sendable () async -> Bool) async throws {
        guard let isBookTombstoned, let prepareDeletedBookCleanup else { return }
        let permit = AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
        for book in try await bookStore.books(for: ownerID) {
            guard await isCurrentIdentity(), !Task.isCancelled else { return }
            guard try await isBookTombstoned(book.id) else { continue }
            guard let operation = lifecycle.admitOwnerOperation(ownerID: ownerID, generation: generation) else { return }
            do {
                guard try await bookStore.deletePermanentlyIfUnchanged(book.id, matching: book, accountPermit: permit) else {
                    operation.release()
                    throw RecoveryError.retryableWorkRemains
                }
                operation.release()
                Log.event("library.delete.restart_reconciled", data: ["book_id": book.id.uuidString])
            } catch { operation.release(); throw error }
        }
        for pending in try await persistence.pendingMaterializationsForDeletionCleanup(ownerID: ownerID) {
            guard await isCurrentIdentity(), !Task.isCancelled else { return }
            let bookID = pending.token.bookID
            guard try await isBookTombstoned(bookID),
                  try await bookStore.book(bookID) == nil,
                  try await persistence.isBookPermanentlyDeleted(bookID: bookID, ownerID: ownerID) else { continue }
            let cleanup = try await prepareDeletedBookCleanup(bookID, ownerID)
            let witness = lifecycle.retireBookForNonLocalDeletion(ownerID: ownerID, generation: pending.token.accountGeneration, bookID: bookID)
            Task.detached { [lifecycle, bookStore, persistence] in
                await lifecycle.waitForRetiredBookDeletion(witness: witness)
                guard await isCurrentIdentity(),
                      let operation = lifecycle.admitOwnerOperation(ownerID: ownerID, generation: generation) else { return }
                defer { operation.release() }
                do {
                    guard try await isBookTombstoned(bookID),
                          try await bookStore.book(bookID) == nil,
                          try await persistence.isBookPermanentlyDeleted(bookID: bookID, ownerID: ownerID),
                          await isCurrentIdentity() else { return }
                    try await cleanup()
                    Log.event("library.delete.cleanup_finished", data: ["book_id": bookID.uuidString, "recovered": "true"])
                } catch { Log.error("library.delete.cleanup_failed", error: error) }
            }
        }
    }

    private func failRecoveryWaiters(_ claim: BookImportRecoveryClaim, token: BookMaterializationToken, book: Book) async {
        guard let permit = claim.sourceFailurePermit(for: token) else { return }
        _ = await lifecycle.failPendingBookSource(book: book, permit: permit)
    }

    private func failUnresolvedRecoveryWaiters(
        claimBookIDs: Set<BookID>,
        claims: [BookID: BookImportRecoveryClaim],
        books: [BookID: Book],
        tokens: [BookID: BookMaterializationToken],
        permits: [BookID: BookImportRecoverySourceFailurePermit]
    ) async {
        for bookID in claimBookIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let book = books[bookID] else { continue }
            if let permit = permits[bookID] {
                _ = await lifecycle.failPendingBookSource(book: book, permit: permit)
            } else if let claim = claims[bookID], let token = tokens[bookID] {
                await failRecoveryWaiters(claim, token: token, book: book)
            }
        }
    }

    private func cleanupReadyOwnedSources(books: [Book], ownerID: UserID, generation: UInt64) async {
        guard let prepareOwnedSourceCleanup else { return }
        let importsURL = rootURL.appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
        for book in books where book.userId == ownerID {
            guard let job = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id,
                ownerID: ownerID,
                currentGeneration: generation
            ), job.phase == .ready, case .ownedStaging = job.sourceKind,
               let relative = job.ownedSourceRelativePath,
               let fingerprint = try? await persistence.fingerprint(bookID: book.id, ownerID: ownerID),
               fingerprint.bookID == book.id,
               fingerprint.ownerID == ownerID,
               fingerprint.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame,
               fingerprint.version.fileIdentifier == job.destinationFileIdentifier,
               fingerprint.version.materializationRevision == job.promotionRevision,
               let sourceURL = Self.containedURL(relative, rootURL: rootURL) else { continue }
            let components = relative.split(separator: "/")
            guard components.count == 3,
                  components[0] == "Imports",
                  UUID(uuidString: String(components[1])) != nil,
                  components[2].hasPrefix("source."),
                  String(components[2].dropFirst("source.".count)).lowercased() == book.formatType.rawValue.lowercased() else { continue }
            let attemptDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
            let destinationURL = rootURL.appendingPathComponent(book.fileURL).standardizedFileURL
            guard attemptDirectory.deletingLastPathComponent() == importsURL,
                  sourceURL.deletingLastPathComponent() == attemptDirectory,
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  FileManager.default.fileExists(atPath: destinationURL.path),
                  let destinationProbe = try? await CoordinatedSourceProbe().probe(
                    destinationURL,
                    materializationRevision: fingerprint.version.materializationRevision
                  ),
                  destinationProbe.version == fingerprint.version,
                  destinationProbe.byteCount == fingerprint.version.byteCount,
                  destinationProbe.sha256.caseInsensitiveCompare(fingerprint.sha256) == .orderedSame,
                  await prepareOwnedSourceCleanup(job.token) else { continue }
            try? FileManager.default.removeItem(at: attemptDirectory)
        }
    }

    private func pauseAdoptedAttempt(_ token: BookMaterializationToken) async {
        guard let pending = try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token,
              pending.phase != .ready,
              pending.phase != .failed,
              pending.phase != .cancelled else { return }
        _ = try? await persistence.transition(token: token, from: pending.phase, to: .paused)
    }

    private func verify(job: PendingBookMaterialization) -> ArtifactVerification {
        guard job.expectedByteCount >= 0 else { return .invalid }
        if [.registered, .copying, .paused].contains(job.phase), job.preparedFileIdentifier == nil,
           job.destinationFileIdentifier == nil, job.promotionRevision == nil {
            return .verified(VerifiedBookArtifacts(
                sha256: job.expectedSHA256.lowercased(),
                byteCount: job.expectedByteCount,
                stagingRelativePath: job.stagingRelativePath,
                destinationRelativePath: job.destinationRelativePath,
                preparedFileIdentifier: nil,
                destinationFileIdentifier: nil,
                promotionRevision: nil
            ))
        }
        guard let preparedID = job.preparedFileIdentifier,
              !preparedID.isEmpty,
              let stagingURL = Self.containedURL(job.stagingRelativePath, rootURL: rootURL) else { return .invalid }

        var transientFailure = false
        var stagedDigest: (sha256: String, count: Int64)?
        do {
            if let stagedVersion = try fileVersionInspector.managedFileVersion(at: stagingURL, materializationRevision: job.sourceVersion.materializationRevision) {
                if stagedVersion.byteCount == job.expectedByteCount,
                   stagedVersion.fileIdentifier == preparedID {
                    do {
                        let digest = try Self.digestAndCount(stagingURL)
                        if digest.count == job.expectedByteCount,
                           digest.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame {
                            stagedDigest = digest
                        }
                    } catch {
                        transientFailure = true
                    }
                }
            }
        } catch {
            transientFailure = true
        }

        var destinationIdentifier: String?
        var destinationDigest: (sha256: String, count: Int64)?
        let destinationExpectedID = job.destinationFileIdentifier
            ?? ((job.phase == .promoting || (job.phase == .paused && job.promotionRevision != nil)) ? preparedID : nil)
        if let expectedID = destinationExpectedID,
           let promotionRevision = job.promotionRevision,
           let destinationURL = Self.containedURL(job.destinationRelativePath, rootURL: rootURL) {
            do {
                if let version = try fileVersionInspector.managedFileVersion(at: destinationURL, materializationRevision: promotionRevision) {
                    if version.byteCount == job.expectedByteCount,
                       version.fileIdentifier == expectedID,
                       version.materializationRevision == promotionRevision {
                        do {
                            let digest = try Self.digestAndCount(destinationURL)
                            if digest.count == job.expectedByteCount,
                               digest.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame {
                                destinationIdentifier = expectedID
                                destinationDigest = digest
                            }
                        } catch {
                            transientFailure = true
                        }
                    }
                }
            } catch {
                transientFailure = true
            }
        }

        if job.phase == .prepared, stagedDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .promoted, destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .promoting, stagedDigest == nil && destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .paused, stagedDigest == nil && destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        guard let verifiedDigest = stagedDigest ?? destinationDigest else { return transientFailure ? .retryable : .invalid }

        return .verified(VerifiedBookArtifacts(
            sha256: verifiedDigest.sha256.lowercased(),
            byteCount: verifiedDigest.count,
            stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: preparedID,
            destinationFileIdentifier: job.destinationFileIdentifier,
            promotionRevision: job.promotionRevision
        ))
    }

    private static func isWaitingForPicker(_ job: PendingBookMaterialization) -> Bool {
        job.phase == .paused
            && (job.retryableErrorCode == "recovery_artifact_invalid"
                || job.retryableErrorCode == "recovery_source_unavailable")
    }

    private static func containedURL(_ relativePath: String, rootURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix) else { return nil }
        return url
    }

    private static func removeRetiredPartialIfSafe(relativePath: String, retiredAttemptID: UUID, rootURL: URL) {
        let expectedPath = "Imports/\(retiredAttemptID.uuidString)/content.partial"
        guard relativePath == expectedPath,
              let url = containedURL(relativePath, rootURL: rootURL),
              FileManager.default.fileExists(atPath: url.path) else { return }
        // Recovery drains the previous book attempt before adoption. The
        // UUID-derived path is that attempt's only staging file, so remove
        // only the partial file and preserve directories and destination.
        try? FileManager.default.removeItem(at: url)
    }

    private static func digestAndCount(_ url: URL) throws -> (sha256: String, count: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            count += Int64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
