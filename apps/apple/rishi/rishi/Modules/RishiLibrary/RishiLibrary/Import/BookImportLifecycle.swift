import Foundation

public struct BookDeletionRetirementWitness: Sendable, Equatable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    public let operationID: UUID
    public let retiredToken: BookMaterializationToken?

    public init(ownerID: UserID, generation: UInt64, bookID: BookID, operationID: UUID, retiredToken: BookMaterializationToken?) {
        self.ownerID = ownerID
        self.generation = generation
        self.bookID = bookID
        self.operationID = operationID
        self.retiredToken = retiredToken
    }
}

/// Exact ownership of temporary source quiescence for a live inbound download.
/// This token never grants deletion rollback or reuse of a retired identity.
public struct BookSourceReplacementToken: Sendable, Equatable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    public let operationID: UUID
}

public struct BookImportProvisionalRollbackLease: Sendable, Equatable {
    public let id: UUID
    public let witness: BookDeletionRetirementWitness
}

public enum BookDeletionRollbackResult: Sendable, Equatable {
    case ready(BookMaterializationToken)
    case retryablePaused(BookMaterializationToken)
    case conflict(BookMaterializationToken)
    /// The unchanged already-ready rollback path restored Book-level access
    /// without entering targeted sample-repair recovery.
    case existingReady
    case refused

    public var didRestoreBook: Bool {
        switch self {
        case .ready, .retryablePaused, .existingReady: true
        case .conflict, .refused: false
        }
    }
}

public struct BookImportActivationToken: Sendable, Equatable {
    public let ownerID: UserID
    public let generation: UInt64
    public let transitionEpoch: UInt64

    public init(ownerID: UserID, generation: UInt64, transitionEpoch: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
        self.transitionEpoch = transitionEpoch
    }
}

public enum BookImportPromotionError: Error, Sendable, Equatable {
    case retired
    case staleAttempt
}

/// Account/book lifetime barrier shared by import work, source leases and
/// account cleanup. Fence is synchronous; physical teardown waits until
/// admitted operations have returned.
public final class BookImportLifecycle: @unchecked Sendable {
    private struct Key: Hashable {
        let ownerID: UserID
        let generation: UInt64
    }

    private struct BookKey: Hashable {
        let ownerID: UserID
        let generation: UInt64
        let bookID: BookID
    }

    private struct ActiveBookAttempt {
        let token: BookMaterializationToken
        var count: Int
        var recoveryOwned: Bool
        var rollbackLeaseID: UUID?
    }

    private struct RecoveryClaimState {
        let id: UUID
        let expectedToken: BookMaterializationToken?
        let rollbackLeaseID: UUID?
        var permittedAttempt: BookMaterializationToken?
        var databaseSuccessorToken: BookMaterializationToken?
    }

    /// Exact DB CAS successors remain attributable to one deletion witness
    /// after a recovery claim is released or cancelled. This is not general
    /// permission to accept the latest token: every consumer also checks the
    /// current witness and exact persisted job.
    private struct DeletionRecoverySuccessor {
        let witness: BookDeletionRetirementWitness
        let token: BookMaterializationToken
    }

    private struct RetryClaimState {
        let id: UUID
        let retiring: BookMaterializationToken
        var activated: BookMaterializationToken?
    }

    private let lock = NSLock()
    private var fenced = Set<Key>()
    private var transitioningOwners = Set<UserID>()
    private var transitionEpochs: [UserID: UInt64] = [:]
    private var ownerOperations: [Key: Int] = [:]
    private var operationWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    private var activeBookAttempts: [BookKey: ActiveBookAttempt] = [:]
    /// Permanently closes effect admission after local/remote retirement.
    /// BookIDs cannot be reused after a tombstone within this account
    /// generation, so this fence intentionally has no reopen operation.
    private var sourceReplacements: [BookKey: BookSourceReplacementToken] = [:]
    private var retiredBooks = Set<BookKey>()
    private var retiredBookAttempts = Set<BookMaterializationToken>()
    private var latestBookAttemptTokens: [BookKey: BookMaterializationToken] = [:]
    private var deletionRetirementWitnesses: [BookKey: BookDeletionRetirementWitness] = [:]
    private var deletionRecoverySuccessors: [BookKey: DeletionRecoverySuccessor] = [:]
    private var provisionalRollbackLeases: [BookKey: BookImportProvisionalRollbackLease] = [:]
    private var recoveryClaims: [BookKey: RecoveryClaimState] = [:]
    private var retryClaims: [BookKey: RetryClaimState] = [:]
    private var recoveryClaimWaiters: [BookKey: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    private var bookRegistrations: [BookKey: Int] = [:]
    private var ownerRegistrationAdmissions: [Key: Int] = [:]
    private var bookAttemptWaiters: [BookKey: [CheckedContinuation<Void, Never>]] = [:]
    private let promotionMutex = BookPromotionMutex()
    private let sourceRegistry: BookSourceRegistry
    private let currentAccountGeneration: @Sendable () async -> UInt64?
    private let cancelOwnerWork: @Sendable (UserID, UInt64) -> Void
    private let drainOwnerWork: @Sendable (UserID, UInt64) async -> Void
    private let cancelBookWork: @Sendable (UserID, UInt64, BookID) -> Void
    private let drainBookWork: @Sendable (UserID, UInt64, BookID) async -> Void

    public init(
        sourceRegistry: BookSourceRegistry,
        currentAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        cancelOwnerWork: @escaping @Sendable (UserID, UInt64) -> Void = { _, _ in },
        drainOwnerWork: @escaping @Sendable (UserID, UInt64) async -> Void = { _, _ in },
        cancelBookWork: @escaping @Sendable (UserID, UInt64, BookID) -> Void = { _, _, _ in },
        drainBookWork: @escaping @Sendable (UserID, UInt64, BookID) async -> Void = { _, _, _ in }
    ) {
        self.sourceRegistry = sourceRegistry
        self.currentAccountGeneration = currentAccountGeneration
        self.cancelOwnerWork = cancelOwnerWork
        self.drainOwnerWork = drainOwnerWork
        self.cancelBookWork = cancelBookWork
        self.drainBookWork = drainBookWork
    }

    /// Closes admission before account generation changes. Existing leases
    /// own their scopes; drains wait for admitted effects and import work.
    @discardableResult
    public func fenceAccount(ownerID: UserID, generation: UInt64) -> BookImportActivationToken {
        lock.lock()
        let firstFence = fenced.insert(Key(ownerID: ownerID, generation: generation)).inserted
        transitioningOwners.insert(ownerID)
        lock.unlock()
        promotionMutex.retireOwner(ownerID: ownerID, generation: generation)
        let epoch = sourceRegistry.fenceAccountSynchronously(ownerID: ownerID, generation: generation)
        lock.lock()
        transitionEpochs[ownerID] = max(transitionEpochs[ownerID] ?? 0, epoch)
        lock.unlock()
        let token = BookImportActivationToken(ownerID: ownerID, generation: generation, transitionEpoch: epoch)
        guard firstFence else { return token }
        cancelOwnerWork(ownerID, generation)
        Task { await sourceRegistry.retire(ownerID: ownerID, generation: generation) }
        return token
    }

    public func drainAccount(_ ownerID: UserID, generation: UInt64) async {
        let key = Key(ownerID: ownerID, generation: generation)
        let alreadyFenced = isFenced(key)
        if !alreadyFenced { _ = fenceAccount(ownerID: ownerID, generation: generation) }
        await drainOwnerOperations(ownerID: ownerID, generation: generation)
        await drainOwnerWork(ownerID, generation)
        await promotionMutex.drainOwner(ownerID: ownerID, generation: generation)
        await sourceRegistry.retire(ownerID: ownerID, generation: generation)
        await sourceRegistry.drain(ownerID: ownerID, generation: generation)
    }

    public func retireBook(ownerID: UserID, generation: UInt64, bookID: BookID) {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock()
        deletionRetirementWitnesses.removeValue(forKey: key)
        deletionRecoverySuccessors.removeValue(forKey: key)
        provisionalRollbackLeases.removeValue(forKey: key)
        retiredBooks.insert(key)
        if let token = activeBookAttempts[key]?.token ?? latestBookAttemptTokens[key] {
            retiredBookAttempts.insert(token)
        }
        lock.unlock()
        promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
        sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
        cancelBookWork(ownerID, generation, bookID)
    }

    /// Fences a local deletion and returns immutable proof of the exact
    /// attempt retired at that synchronous transition.
    @discardableResult
    public func retireBookForDeletion(ownerID: UserID, generation: UInt64, bookID: BookID) -> BookDeletionRetirementWitness {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock()
        retiredBooks.insert(key)
        provisionalRollbackLeases.removeValue(forKey: key)
        let token = activeBookAttempts[key]?.token ?? latestBookAttemptTokens[key]
        if let token { retiredBookAttempts.insert(token) }
        let witness = BookDeletionRetirementWitness(
            ownerID: ownerID, generation: generation, bookID: bookID,
            operationID: UUID(), retiredToken: token
        )
        deletionRetirementWitnesses[key] = witness
        deletionRecoverySuccessors.removeValue(forKey: key)
        lock.unlock()
        promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
        sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
        cancelBookWork(ownerID, generation, bookID)
        return witness
    }

    /// Remote deletion and restart cleanup share an existing local proof.
    /// A fresh non-local drain witness does not grant local rollback authority.
    public func retireBookForNonLocalDeletion(ownerID: UserID, generation: UInt64, bookID: BookID) -> BookDeletionRetirementWitness {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock()
        retiredBooks.insert(key)
        provisionalRollbackLeases.removeValue(forKey: key)
        let token = activeBookAttempts[key]?.token ?? latestBookAttemptTokens[key]
        if let token { retiredBookAttempts.insert(token) }
        let witness = deletionRetirementWitnesses[key] ?? BookDeletionRetirementWitness(
            ownerID: ownerID, generation: generation, bookID: bookID,
            operationID: UUID(), retiredToken: token
        )
        lock.unlock()
        promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
        sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
        cancelBookWork(ownerID, generation, bookID)
        return witness
    }

    /// Temporarily opens only the underlying per-Book gates for one targeted
    /// recovery. The lifecycle retirement and witness remain live, so ordinary
    /// registration/retry paths stay denied until verified finalization.
    public func beginProvisionalDeletionRollback(
        witness: BookDeletionRetirementWitness
    ) -> BookImportProvisionalRollbackLease? {
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        lock.lock()
        guard deletionRetirementWitnesses[key] == witness,
              retiredBooks.contains(key),
              !transitioningOwners.contains(witness.ownerID),
              !fenced.contains(Key(ownerID: witness.ownerID, generation: witness.generation)),
              activeBookAttempts[key] == nil,
              recoveryClaims[key] == nil,
              retryClaims[key] == nil,
              provisionalRollbackLeases[key] == nil,
              sourceRegistry.activateBookSynchronously(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID) else {
            lock.unlock()
            return nil
        }
        guard promotionMutex.restoreBook(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID) else {
            sourceRegistry.fenceBookSynchronously(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
            lock.unlock()
            return nil
        }
        let lease = BookImportProvisionalRollbackLease(id: UUID(), witness: witness)
        provisionalRollbackLeases[key] = lease
        lock.unlock()
        return lease
    }

    /// Re-fences a failed provisional rollback without consuming its witness.
    /// If a newer deletion or account fence has already won, it owns the gates.
    public func abortProvisionalDeletionRollback(_ lease: BookImportProvisionalRollbackLease) {
        let witness = lease.witness
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        lock.lock()
        guard provisionalRollbackLeases[key] == lease,
              deletionRetirementWitnesses[key] == witness,
              retiredBooks.contains(key) else {
            lock.unlock()
            return
        }
        sourceRegistry.fenceBookSynchronously(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        promotionMutex.retireBook(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        provisionalRollbackLeases.removeValue(forKey: key)
        lock.unlock()
    }

    /// Consumes a provisional rollback only after its caller verifies durable
    /// ready/paused authority. A paused token remains retired until a fresh CAS.
    public func finalizeProvisionalDeletionRollback(
        _ lease: BookImportProvisionalRollbackLease,
        result: BookDeletionRollbackResult
    ) -> Bool {
        let witness = lease.witness
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        let token: BookMaterializationToken
        let isPaused: Bool
        switch result {
        case let .ready(value): token = value; isPaused = false
        case let .retryablePaused(value): token = value; isPaused = true
        case .conflict, .existingReady, .refused: abortProvisionalDeletionRollback(lease); return false
        }
        lock.lock()
        guard provisionalRollbackLeases[key] == lease,
              deletionRetirementWitnesses[key] == witness,
              retiredBooks.contains(key),
              !transitioningOwners.contains(witness.ownerID),
              !fenced.contains(Key(ownerID: witness.ownerID, generation: witness.generation)),
              activeBookAttempts[key] == nil,
              recoveryClaims[key] == nil,
              token.ownerID == witness.ownerID,
              token.accountGeneration == witness.generation,
              token.bookID == witness.bookID,
              latestBookAttemptTokens[key] == token,
              !retiredBookAttempts.contains(token) else {
            lock.unlock()
            abortProvisionalDeletionRollback(lease)
            return false
        }
        if isPaused { retiredBookAttempts.insert(token) }
        retiredBooks.remove(key)
        deletionRetirementWitnesses.removeValue(forKey: key)
        deletionRecoverySuccessors.removeValue(forKey: key)
        provisionalRollbackLeases.removeValue(forKey: key)
        lock.unlock()
        return true
    }

    public func isBookRetiredForDeletion(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        return lock.withLock { self.retiredBooks.contains(key) && self.deletionRetirementWitnesses[key] != nil }
    }

    public func isCurrentDeletionRetirementWitness(_ witness: BookDeletionRetirementWitness) -> Bool {
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        return lock.withLock {
            self.deletionRetirementWitnesses[key] == witness
                && self.retiredBooks.contains(key)
                && !self.transitioningOwners.contains(witness.ownerID)
                && !self.fenced.contains(Key(ownerID: witness.ownerID, generation: witness.generation))
        }
    }

    public func isCurrentProvisionalDeletionRollbackLease(_ lease: BookImportProvisionalRollbackLease) -> Bool {
        let witness = lease.witness
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        return lock.withLock {
            self.provisionalRollbackLeases[key] == lease
                && self.deletionRetirementWitnesses[key] == witness
                && self.retiredBooks.contains(key)
                && !self.transitioningOwners.contains(witness.ownerID)
                && !self.fenced.contains(Key(ownerID: witness.ownerID, generation: witness.generation))
        }
    }

    /// Quiesces live bytes without manufacturing a deletion retirement.
    /// The temporary claim rejects new registrations while genuine entered
    /// work drains. Local deletion always wins and keeps its exact witness.
    public func prepareBookSourceReplacement(ownerID: UserID, generation: UInt64, bookID: BookID, onFailure: (@Sendable (BookSourceReplacementToken) async -> Void)? = nil) async throws -> BookSourceReplacementToken {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        guard await currentAccountGeneration().map({ $0 == generation }) ?? true else { throw BookImportPromotionError.retired }
        let token = try lock.withLock { () throws -> BookSourceReplacementToken in
            guard !transitioningOwners.contains(ownerID), !fenced.contains(Key(ownerID: ownerID, generation: generation)),
                  !retiredBooks.contains(key), deletionRetirementWitnesses[key] == nil,
                  sourceReplacements[key] == nil, recoveryClaims[key] == nil, retryClaims[key] == nil else { throw BookImportPromotionError.retired }
            let token = BookSourceReplacementToken(ownerID: ownerID, generation: generation, bookID: bookID, operationID: UUID())
            sourceReplacements[key] = token
            promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
            sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
            return token
        }
        cancelBookWork(ownerID, generation, bookID)
        await drainBookMaterializations(ownerID: ownerID, generation: generation, bookID: bookID)
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await sourceRegistry.retireSource(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainBookWork(ownerID, generation, bookID)
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        do {
            try Task.checkCancellation()
            guard await currentAccountGeneration().map({ $0 == generation }) ?? true,
                  lock.withLock({ sourceReplacements[key] == token && !retiredBooks.contains(key) && deletionRetirementWitnesses[key] == nil && !transitioningOwners.contains(ownerID) && !fenced.contains(Key(ownerID: ownerID, generation: generation)) }) else { throw BookImportPromotionError.retired }
            return token
        } catch {
            // Preserve exact ownership until the native caller has finished
            // cancellation-independent, original-authority cleanup.
            if let onFailure { await onFailure(token) }
            else { abortBookSourceReplacement(token, restoreSource: false) }
            throw error
        }
    }

    /// Called under the native live-identity commit gate after verified bytes,
    /// fingerprint and original account authority have all been accepted.
    @discardableResult
    public func completeBookSourceReplacement(_ token: BookSourceReplacementToken) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.generation, bookID: token.bookID)
        return lock.withLock {
            guard sourceReplacements[key] == token,
                  !retiredBooks.contains(key), deletionRetirementWitnesses[key] == nil,
                  !transitioningOwners.contains(token.ownerID), !fenced.contains(Key(ownerID: token.ownerID, generation: token.generation)),
                  activeBookAttempts[key] == nil,
                  promotionMutex.restoreBook(ownerID: token.ownerID, generation: token.generation, bookID: token.bookID),
                  sourceRegistry.activateBookSynchronously(ownerID: token.ownerID, generation: token.generation, bookID: token.bookID) else { return false }
            sourceReplacements.removeValue(forKey: key)
            return true
        }
    }

    /// Restore only while the caller owns the same native live-identity gate.
    /// A rejected/obsolete token releases its temporary claim without opening
    /// any permanent source, lifecycle, promotion or account retirement.
    public func abortBookSourceReplacement(_ token: BookSourceReplacementToken, restoreSource: Bool) {
        if restoreSource, completeBookSourceReplacement(token) { return }
        let key = BookKey(ownerID: token.ownerID, generation: token.generation, bookID: token.bookID)
        lock.withLock { if sourceReplacements[key] == token { sourceReplacements.removeValue(forKey: key) } }
    }

    public func drainBook(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainBookMaterializations(ownerID: ownerID, generation: generation, bookID: bookID)
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await sourceRegistry.retireSource(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainBookWork(ownerID, generation, bookID)
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    public func drainBookForDeletion(ownerID: UserID, generation: UInt64, bookID: BookID) async -> BookDeletionRetirementWitness {
        let witness = retireBookForDeletion(ownerID: ownerID, generation: generation, bookID: bookID)
        await waitForRetiredBookDeletion(witness: witness)
        return witness
    }

    /// Physical cleanup waits on the original retirement, independently of
    /// the already committed logical deletion. Never replace its witness.
    public func waitForRetiredBookDeletion(witness: BookDeletionRetirementWitness) async {
        let ownerID = witness.ownerID
        let generation = witness.generation
        let bookID = witness.bookID
        _ = await waitForBookRecoveryClaimIfPresent(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainBookMaterializations(ownerID: ownerID, generation: generation, bookID: bookID)
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await sourceRegistry.retireSource(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainBookWork(ownerID, generation, bookID)
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    /// Reopens source/admission after a failed tombstone write, once the
    /// caller has confirmed the row remains live. The pre-retirement attempt
    /// stays permanently rejected; retries must reserve a fresh attempt token.
    @discardableResult
    public func restoreBookAfterFailedRetirement(witness: BookDeletionRetirementWitness) async -> Bool {
        let ownerID = witness.ownerID
        let generation = witness.generation
        let bookID = witness.bookID
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        return restoreBookAfterFailedRetirementSynchronously(witness: witness)
    }

    private func restoreBookAfterFailedRetirementSynchronously(witness: BookDeletionRetirementWitness) -> Bool {
        let ownerID = witness.ownerID
        let generation = witness.generation
        let bookID = witness.bookID
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        return lock.withLock {
            let latestToken = self.latestBookAttemptTokens[key]
            let retiredAttemptMatches: Bool
            if let retiredToken = witness.retiredToken {
                retiredAttemptMatches = latestToken == retiredToken && self.retiredBookAttempts.contains(retiredToken)
            } else {
                retiredAttemptMatches = latestToken == nil
            }
            guard self.deletionRetirementWitnesses[key] == witness,
                  self.retiredBooks.contains(key),
                  self.activeBookAttempts[key] == nil,
                  retiredAttemptMatches,
                  self.sourceRegistry.activateBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID) else {
                return false
            }
            let promotionRestored = witness.retiredToken.map { token in
                self.promotionMutex.activateAttempt(token, reopenRetiredBookFence: true)
            } ?? self.promotionMutex.restoreBook(ownerID: ownerID, generation: generation, bookID: bookID)
            guard promotionRestored else {
                self.sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
                return false
            }
            self.retiredBooks.remove(key)
            self.deletionRetirementWitnesses.removeValue(forKey: key)
            self.deletionRecoverySuccessors.removeValue(forKey: key)
            return true
        }
    }

    /// Reopens only Book-level admission for a parked sample repair. The
    /// retired token remains rejected by both lifecycle and promotion state.
    public func restoreBookFenceAfterFailedRetirement(
        witness: BookDeletionRetirementWitness,
        parkedRepairToken: BookMaterializationToken
    ) -> Bool {
        let key = BookKey(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
        guard parkedRepairToken.ownerID == witness.ownerID,
              parkedRepairToken.accountGeneration == witness.generation,
              parkedRepairToken.bookID == witness.bookID else { return false }
        lock.lock()
        let latest = latestBookAttemptTokens[key]
        let expectedLatest = witness.retiredToken
        let exactWitnessSuccessor = latest == parkedRepairToken
            && deletionRecoverySuccessors[key]?.witness == witness
            && deletionRecoverySuccessors[key]?.token == parkedRepairToken
        let priorAttemptStillRetired = expectedLatest.map {
            latest == $0 && retiredBookAttempts.contains($0)
        } ?? (latest == nil)
        let retiredAttemptMatches = priorAttemptStillRetired || exactWitnessSuccessor
        guard deletionRetirementWitnesses[key] == witness, retiredBooks.contains(key),
              activeBookAttempts[key] == nil,
              retiredAttemptMatches,
              sourceRegistry.activateBookSynchronously(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID) else {
            lock.unlock()
            return false
        }
        guard promotionMutex.restoreBook(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID) else {
            sourceRegistry.fenceBookSynchronously(ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID)
            lock.unlock()
            return false
        }
        promotionMutex.retireAttempt(parkedRepairToken)
        retiredBookAttempts.insert(parkedRepairToken)
        latestBookAttemptTokens[key] = parkedRepairToken
        retiredBooks.remove(key)
        deletionRetirementWitnesses.removeValue(forKey: key)
        deletionRecoverySuccessors.removeValue(forKey: key)
        lock.unlock()
        return true
    }

    /// Compatibility restoration for non-local deletion flows that retain the
    /// prior ready-source contract. Local UI deletion must use a witness.
    @discardableResult
    public func restoreBookAfterFailedRetirement(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        retiredToken: BookMaterializationToken? = nil
    ) async -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        guard lock.withLock({ deletionRetirementWitnesses[key] == nil }) else { return false }
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        guard lock.withLock({ deletionRetirementWitnesses[key] == nil }) else { return false }
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        return lock.withLock {
            let latestToken = latestBookAttemptTokens[key]
            let retiredAttemptMatches: Bool
            if let retiredToken {
                retiredAttemptMatches = latestToken == retiredToken && retiredBookAttempts.contains(retiredToken)
            } else {
                retiredAttemptMatches = latestToken.map(retiredBookAttempts.contains) ?? true
            }
            guard deletionRetirementWitnesses[key] == nil,
                  retiredBooks.contains(key), activeBookAttempts[key] == nil, retiredAttemptMatches,
                  sourceRegistry.activateBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID) else { return false }
            let promotionRestored = retiredToken.map { promotionMutex.activateAttempt($0, reopenRetiredBookFence: true) }
                ?? promotionMutex.restoreBook(ownerID: ownerID, generation: generation, bookID: bookID)
            guard promotionRestored else {
                sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
                return false
            }
            retiredBooks.remove(key)
            return true
        }
    }

    public func admits(ownerID: UserID, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !transitioningOwners.contains(ownerID) && !fenced.contains(Key(ownerID: ownerID, generation: generation))
    }

    /// Admits one account-owned operation while the generation is open.
    /// Callers hold the returned token through their final callback or cleanup.
    public func admitOwnerOperation(ownerID: UserID, generation: UInt64) -> BookImportOperationLease? {
        let key = Key(ownerID: ownerID, generation: generation)
        lock.lock(); defer { lock.unlock() }
        guard !transitioningOwners.contains(ownerID), !fenced.contains(key) else { return nil }
        ownerOperations[key, default: 0] += 1
        return BookImportOperationLease(generation: generation) { [weak self] in self?.finishOwnerOperation(key) }
    }

    public func admitCurrentOwnerOperation(ownerID: UserID) async -> BookImportOperationLease? {
        guard let generation = await currentAccountGeneration() else { return nil }
        return admitOwnerOperation(ownerID: ownerID, generation: generation)
    }

    /// Tracks a materialization attempt for its complete public operation,
    /// including source resolution, copy, promotion, and ready publication.
    /// A recovery claim and a user attempt contend on the same lock/key.
    public func admitBookMaterialization(
        _ token: BookMaterializationToken,
        provisionalRollbackLease: BookImportProvisionalRollbackLease? = nil
    ) -> BookImportMaterializationAdmission? {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        let rollbackLeaseID = provisionalRollbackLease?.id
        let rollbackLeaseIsCurrent = provisionalRollbackLease.map {
            self.provisionalRollbackLeases[key] == $0
                && self.deletionRetirementWitnesses[key] == $0.witness
                && $0.witness.ownerID == token.ownerID
                && $0.witness.generation == token.accountGeneration
                && $0.witness.bookID == token.bookID
        } ?? false
        guard !transitioningOwners.contains(token.ownerID),
              !fenced.contains(Key(ownerID: token.ownerID, generation: token.accountGeneration)),
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil,
              (provisionalRollbackLease == nil || rollbackLeaseIsCurrent),
              !retryClaims.contains(where: { $0.key.ownerID == token.ownerID && $0.key.bookID == token.bookID && $0.value.activated != token }) else {
            lock.unlock()
            return nil
        }
        if let claim = recoveryClaims.first(where: { $0.key.ownerID == token.ownerID && $0.key.bookID == token.bookID })?.value,
           claim.permittedAttempt != token {
            lock.unlock()
            return nil
        }
        if var active = activeBookAttempts[key] {
            guard active.token == token, !retiredBookAttempts.contains(token),
                  active.rollbackLeaseID == nil || active.rollbackLeaseID == rollbackLeaseID else {
                lock.unlock()
                return nil
            }
            active.count += 1
            activeBookAttempts[key] = active
        } else {
            guard provisionalRollbackLease == nil, !retiredBookAttempts.contains(token) else {
                lock.unlock()
                return nil
            }
            activeBookAttempts[key] = ActiveBookAttempt(token: token, count: 1, recoveryOwned: false, rollbackLeaseID: nil)
        }
        latestBookAttemptTokens[key] = token
        let ownerKey = Key(ownerID: token.ownerID, generation: token.accountGeneration)
        ownerOperations[ownerKey, default: 0] += 1
        lock.unlock()
        return BookImportMaterializationAdmission(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID) { [weak self] in
            self?.finishBookMaterialization(key, ownerKey: ownerKey, token: token)
        }
    }

    /// Reserves a book's recovery gate before its registration row is written.
    /// It may coexist with an already-running attempt so duplicate selections
    /// can still join; recovery cannot claim the book until this lease ends.
    public func admitBookRegistration(ownerID: UserID, generation: UInt64, bookID: BookID) -> BookImportMaterializationAdmission? {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        let ownerKey = Key(ownerID: ownerID, generation: generation)
        lock.lock()
        guard !transitioningOwners.contains(ownerID),
              !fenced.contains(ownerKey),
              !retiredBooks.contains(key), sourceReplacements[key] == nil,
              recoveryClaims[key] == nil, retryClaims[key] == nil,
              activeBookAttempts[key]?.recoveryOwned != true else {
            lock.unlock()
            return nil
        }
        bookRegistrations[key, default: 0] += 1
        ownerRegistrationAdmissions[ownerKey, default: 0] += 1
        ownerOperations[ownerKey, default: 0] += 1
        lock.unlock()
        return BookImportMaterializationAdmission(ownerID: ownerID, generation: generation, bookID: bookID) { [weak self] in
            self?.finishBookRegistration(key, ownerKey: ownerKey)
        }
    }

    /// Waits for an in-progress recovery handoff for this exact book. Returns
    /// immediately with `false` when no recovery claim is blocking admission.
    public func waitForBookRecoveryClaimIfPresent(ownerID: UserID, generation: UInt64, bookID: BookID) async -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        let waiterID = UUID()
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled,
                      recoveryClaims[key] != nil || activeBookAttempts[key]?.recoveryOwned == true else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                recoveryClaimWaiters[key, default: [:]][waiterID] = continuation
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.cancelBookRecoveryWaiter(key, waiterID: waiterID)
        }
    }

    func hasRecoveryClaimWaiterForTesting(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock(); defer { lock.unlock() }
        return !(recoveryClaimWaiters[key]?.isEmpty ?? true)
    }

    /// Completes readers waiting on a source whose recovery resume failed.
    /// Persisted `.paused` state remains available for a later picker retry.
    public func failPendingBookSource(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        await sourceRegistry.failPendingSource(
            ownerID: ownerID,
            generation: generation,
            bookID: bookID,
            error: BookSourceRegistryError.unavailable
        )
    }

    /// Atomically reserves a book's recovery window only if no materialization
    /// is active. New attempts are rejected until this claim releases.
    public func claimBookRecovery(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        expectedToken: BookMaterializationToken? = nil,
        provisionalRollbackLease: BookImportProvisionalRollbackLease? = nil
    ) -> BookImportRecoveryClaim? {
        guard expectedToken.map({ token in
            token.ownerID == ownerID && token.bookID == bookID
                && (provisionalRollbackLease == nil || token.accountGeneration == generation)
        }) ?? true else { return nil }
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        let id = UUID()
        lock.lock()
        let rollbackLeaseIsCurrent = provisionalRollbackLease.map {
            $0.witness.ownerID == ownerID && $0.witness.generation == generation && $0.witness.bookID == bookID
                && self.provisionalRollbackLeases[key] == $0
                && self.deletionRetirementWitnesses[key] == $0.witness
        } ?? false
        let hasActiveAttempt = activeBookAttempts.contains { $0.key.ownerID == ownerID && $0.key.bookID == bookID && $0.value.count > 0 }
        let hasRegistration = bookRegistrations.contains { $0.key.ownerID == ownerID && $0.key.bookID == bookID && $0.value > 0 }
        let hasOwnerRegistration = ownerRegistrationAdmissions[Key(ownerID: ownerID, generation: generation), default: 0] > 0
        let hasRecoveryClaim = recoveryClaims.keys.contains { $0.ownerID == ownerID && $0.bookID == bookID }
        let hasRetryClaim = retryClaims.keys.contains { $0.ownerID == ownerID && $0.bookID == bookID }
        guard (provisionalRollbackLease == nil || rollbackLeaseIsCurrent),
              !transitioningOwners.contains(ownerID),
              !fenced.contains(Key(ownerID: ownerID, generation: generation)),
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil,
              !hasActiveAttempt,
              !hasRegistration,
              !hasOwnerRegistration,
              !hasRecoveryClaim, !hasRetryClaim else {
            lock.unlock()
            return nil
        }
        recoveryClaims[key] = RecoveryClaimState(
            id: id, expectedToken: expectedToken,
            rollbackLeaseID: rollbackLeaseIsCurrent ? provisionalRollbackLease?.id : nil,
            permittedAttempt: nil,
            databaseSuccessorToken: nil
        )
        let ownerKey = Key(ownerID: ownerID, generation: generation)
        ownerOperations[ownerKey, default: 0] += 1
        lock.unlock()
        return BookImportRecoveryClaim(ownerID: ownerID, generation: generation, bookID: bookID,
                                       drainPriorAttempt: { [weak self] in
                                           guard let self, let expectedToken else { return }
                                           await self.drainRecoveryAttempt(expectedToken)
                                       },
                                       allowAttempt: { [weak self] token in self?.permitRecoveryAttempt(key, claimID: id, token: token) ?? false },
                                       promoteAttempt: { [weak self] token in self?.promoteRecoveryAttempt(key, ownerKey: ownerKey, claimID: id, token: token) },
                                       makeFailurePermit: { [weak self] token in self?.makeRecoveryFailurePermit(key, claimID: id, token: token) },
                                       recordDatabaseSuccessor: { [weak self] token, lease in
                                           self?.recordRecoveryDatabaseSuccessor(key, claimID: id, token: token, lease: lease) ?? false
                                       },
                                       recordPausedAttempt: { [weak self] token, lease in
                                           self?.recordProvisionalRollbackPausedAttempt(key, claimID: id, token: token, lease: lease) ?? false
                                       },
                                       release: { [weak self] in self?.releaseRecoveryClaim(key, ownerKey: ownerKey, claimID: id) })
    }

    /// Records the exact token returned by a successful recovery CAS before
    /// any subsequent suspension can observe cancellation. This successor is
    /// scoped to the live deletion lease and recovery claim.
    private func recordRecoveryDatabaseSuccessor(
        _ key: BookKey,
        claimID: UUID,
        token: BookMaterializationToken,
        lease: BookImportProvisionalRollbackLease
    ) -> Bool {
        lock.withLock {
            guard token.ownerID == key.ownerID,
                  token.accountGeneration == key.generation,
                  token.bookID == key.bookID,
                  self.provisionalRollbackLeases[key] == lease,
                  self.deletionRetirementWitnesses[key] == lease.witness,
                  self.retiredBooks.contains(key),
                  !self.transitioningOwners.contains(key.ownerID),
                  !self.fenced.contains(Key(ownerID: key.ownerID, generation: key.generation)),
                  var claim = self.recoveryClaims[key],
                  claim.id == claimID,
                  claim.rollbackLeaseID == lease.id,
                  claim.databaseSuccessorToken == nil,
                  claim.permittedAttempt == nil,
                  token != claim.expectedToken,
                  token.attemptID != claim.expectedToken?.attemptID,
                  self.latestBookAttemptTokens[key] == claim.expectedToken
                    || self.latestBookAttemptTokens[key] == lease.witness.retiredToken
                    || (self.latestBookAttemptTokens[key] == nil && lease.witness.retiredToken == nil),
                  !self.retiredBookAttempts.contains(token),
                  self.activeBookAttempts[key] == nil else { return false }
            claim.databaseSuccessorToken = token
            self.recoveryClaims[key] = claim
            self.latestBookAttemptTokens[key] = token
            self.deletionRecoverySuccessors[key] = DeletionRecoverySuccessor(
                witness: lease.witness,
                token: token
            )
            return true
        }
    }

    private func recordProvisionalRollbackPausedAttempt(
        _ key: BookKey,
        claimID: UUID,
        token: BookMaterializationToken,
        lease: BookImportProvisionalRollbackLease
    ) -> Bool {
        lock.withLock {
            guard token.ownerID == key.ownerID, token.accountGeneration == key.generation, token.bookID == key.bookID,
                  self.provisionalRollbackLeases[key] == lease,
                  self.deletionRetirementWitnesses[key] == lease.witness,
                  self.recoveryClaims[key]?.id == claimID,
                  self.recoveryClaims[key]?.rollbackLeaseID == lease.id,
                  self.recoveryClaims[key]?.permittedAttempt == token,
                  self.activeBookAttempts[key] == nil,
                  !self.retiredBookAttempts.contains(token),
                  !self.transitioningOwners.contains(key.ownerID),
                  !self.fenced.contains(Key(ownerID: key.ownerID, generation: key.generation)) else { return false }
            self.latestBookAttemptTokens[key] = token
            return true
        }
    }

    /// Owns a retry transition under the current account generation while
    /// retiring exactly the old materialization token. It deliberately keeps
    /// source-reader leases and the permanent book/account fences untouched.
    public func claimAttemptRetry(accountPermit: AccountMutationPermit, retiring token: BookMaterializationToken) -> BookImportRetryClaim? {
        guard accountPermit.ownerID == token.ownerID else { return nil }
        let key = BookKey(ownerID: token.ownerID, generation: accountPermit.accountGeneration, bookID: token.bookID)
        let ownerKey = Key(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration)
        let id = UUID()
        lock.lock()
        let hasRegistration = bookRegistrations.contains { $0.key.ownerID == token.ownerID && $0.key.bookID == token.bookID && $0.value > 0 }
        let hasOtherActive = activeBookAttempts.contains { entry in
            entry.key.ownerID == token.ownerID && entry.key.bookID == token.bookID && entry.value.count > 0 && entry.value.token != token
        }
        let hasOtherRecovery = recoveryClaims.keys.contains { $0.ownerID == token.ownerID && $0.bookID == token.bookID }
        let hasOtherRetry = retryClaims.keys.contains { $0.ownerID == token.ownerID && $0.bookID == token.bookID }
        let hasRetiredCurrentBook = retiredBooks.contains(key)
        let hasUndrainedHistoricalLatest = latestBookAttemptTokens.values.contains { latest in
            latest.ownerID == token.ownerID && latest.bookID == token.bookID && latest != token
                && !isHistoricalGenerationDrainedLocked(latest)
        }
        guard !transitioningOwners.contains(accountPermit.ownerID), !fenced.contains(ownerKey),
              !hasRetiredCurrentBook, !hasRegistration, !hasOtherActive,
              !hasOtherRecovery, !hasOtherRetry, !hasUndrainedHistoricalLatest else {
            lock.unlock()
            return nil
        }
        retryClaims[key] = RetryClaimState(id: id, retiring: token, activated: nil)
        ownerOperations[ownerKey, default: 0] += 1
        retiredBookAttempts.insert(token)
        lock.unlock()
        promotionMutex.retireAttempt(token)
        return BookImportRetryClaim(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration, bookID: token.bookID,
            retiring: token,
            drain: { [weak self] in
                guard let self else { return RetiredBookMaterializationAttempt(token: token) }
                return await self.drainRetryAttempt(token)
            },
            activate: { [weak self] newToken in self?.activateRetryAttempt(key, ownerKey: ownerKey, claimID: id, oldToken: token, newToken: newToken) },
            release: { [weak self] in self?.releaseRetryClaim(key, ownerKey: ownerKey, claimID: id) })
    }

    private func isHistoricalGenerationDrainedLocked(_ token: BookMaterializationToken) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        let ownerKey = Key(ownerID: token.ownerID, generation: token.accountGeneration)
        return fenced.contains(ownerKey)
            && activeBookAttempts[key] == nil && bookRegistrations[key] == nil
            && recoveryClaims[key] == nil && retryClaims[key] == nil
            && ownerOperations[ownerKey] == nil
            && promotionMutex.isDrained(token)
    }

    private func drainRetryAttempt(_ token: BookMaterializationToken) async -> RetiredBookMaterializationAttempt {
        await drainBookMaterializations(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        await promotionMutex.drainBook(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        return RetiredBookMaterializationAttempt(token: token)
    }

    private func activateRetryAttempt(_ key: BookKey, ownerKey: Key, claimID: UUID, oldToken: BookMaterializationToken, newToken: BookMaterializationToken) -> BookImportMaterializationAdmission? {
        lock.lock()
        guard newToken.ownerID == key.ownerID, newToken.accountGeneration == key.generation, newToken.bookID == key.bookID,
              retryClaims[key]?.id == claimID, retryClaims[key]?.retiring == oldToken,
              retryClaims[key]?.activated == nil,
              !transitioningOwners.contains(key.ownerID), !fenced.contains(ownerKey), !retiredBooks.contains(key), sourceReplacements[key] == nil,
              activeBookAttempts[key] == nil else { lock.unlock(); return nil }
        retryClaims[key]?.activated = newToken
        lock.unlock()
        guard promotionMutex.activateAttempt(newToken, reopenRetiredBookFence: false),
              sourceRegistry.advanceBookAttemptSynchronously(ownerID: newToken.ownerID, generation: newToken.accountGeneration, bookID: newToken.bookID) else {
            lock.withLock { if retryClaims[key]?.id == claimID { retryClaims[key]?.activated = nil } }
            return nil
        }
        let transferred = lock.withLock { () -> Bool in
            guard retryClaims[key]?.id == claimID, retryClaims[key]?.activated == newToken,
                  activeBookAttempts[key] == nil,
                  !transitioningOwners.contains(key.ownerID), !fenced.contains(ownerKey), !retiredBooks.contains(key) else {
                if retryClaims[key]?.id == claimID { retryClaims[key]?.activated = nil }
                return false
            }
            activeBookAttempts[key] = ActiveBookAttempt(token: newToken, count: 1, recoveryOwned: false, rollbackLeaseID: nil)
            latestBookAttemptTokens[key] = newToken
            retryClaims.removeValue(forKey: key)
            return true
        }
        guard transferred else { return nil }
        return BookImportMaterializationAdmission(ownerID: newToken.ownerID, generation: newToken.accountGeneration, bookID: newToken.bookID) { [weak self] in self?.finishBookMaterialization(key, ownerKey: ownerKey, token: newToken) }
    }

    private func releaseRetryClaim(_ key: BookKey, ownerKey: Key, claimID: UUID) {
        lock.lock()
        guard retryClaims[key]?.id == claimID else { lock.unlock(); return }
        retryClaims.removeValue(forKey: key)
        let remaining = max(0, ownerOperations[ownerKey, default: 0] - 1)
        if remaining == 0 { ownerOperations.removeValue(forKey: ownerKey) } else { ownerOperations[ownerKey] = remaining }
        let waiters = remaining == 0 ? operationWaiters.removeValue(forKey: ownerKey) ?? [] : []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    /// Serializes the final filesystem promotion for one Book. Retirement
    /// closes the attempt and cancels queued waiters synchronously; drains
    /// wait for a holder without acquiring this mutex themselves.
    public func withPromotionPermit<Value: Sendable>(
        token: BookMaterializationToken,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard admits(ownerID: token.ownerID, generation: token.accountGeneration) else {
            throw BookImportPromotionError.retired
        }
        let tokenRetired = lock.withLock { retiredBookAttempts.contains(token) }
        guard !tokenRetired else { throw BookImportPromotionError.retired }
        let permit = try await promotionMutex.acquire(token)
        defer { permit.release() }
        guard admits(ownerID: token.ownerID, generation: token.accountGeneration) else {
            throw BookImportPromotionError.retired
        }
        return try await operation()
    }

    /// Opens a fresh attempt only after its reservation CAS succeeds and the
    /// previous attempt has drained. Old tokens remain rejected.
    @discardableResult
    public func activatePromotionAttempt(
        _ token: BookMaterializationToken,
        provisionalRollbackLease: BookImportProvisionalRollbackLease? = nil
    ) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        let leaseIsCurrent = provisionalRollbackLease.map {
            self.provisionalRollbackLeases[key] == $0
                && self.deletionRetirementWitnesses[key] == $0.witness
                && self.recoveryClaims[key]?.rollbackLeaseID == $0.id
                && self.recoveryClaims[key]?.permittedAttempt == token
        } ?? false
        let isRetired = retiredBooks.contains(key) && !leaseIsCurrent
        let tokenRetired = retiredBookAttempts.contains(token)
        lock.unlock()
        guard !isRetired, !tokenRetired,
              provisionalRollbackLease == nil || leaseIsCurrent else { return false }
        guard admits(ownerID: token.ownerID, generation: token.accountGeneration) else { return false }
        guard promotionMutex.activateAttempt(token, reopenRetiredBookFence: false),
              sourceRegistry.advanceBookAttemptSynchronously(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID) else { return false }
        return lock.withLock {
            !transitioningOwners.contains(token.ownerID)
                && !fenced.contains(Key(ownerID: token.ownerID, generation: token.accountGeneration))
                && (!retiredBooks.contains(key) || leaseIsCurrent)
                && (provisionalRollbackLease == nil || self.provisionalRollbackLeases[key] == provisionalRollbackLease)
                && !retiredBookAttempts.contains(token)
        }
    }

    /// Reopens work only after the app has finished applying an identity
    /// transition. The old generation remains fenced permanently.
    public func activationToken(ownerID: UserID, generation: UInt64) -> BookImportActivationToken {
        lock.lock()
        let epoch = transitionEpochs[ownerID] ?? sourceRegistry.currentTransitionEpoch(ownerID: ownerID)
        lock.unlock()
        return BookImportActivationToken(ownerID: ownerID, generation: generation, transitionEpoch: epoch)
    }

    @discardableResult
    public func activateAccount(_ token: BookImportActivationToken) -> Bool {
        lock.lock()
        guard transitionEpochs[token.ownerID, default: token.transitionEpoch] == token.transitionEpoch,
              sourceRegistry.activateAccountSynchronously(ownerID: token.ownerID, generation: token.generation, epoch: token.transitionEpoch) else {
            lock.unlock()
            return false
        }
        transitioningOwners.remove(token.ownerID)
        fenced.remove(Key(ownerID: token.ownerID, generation: token.generation))
        lock.unlock()
        return true
    }

    @discardableResult
    public func activateAccount(ownerID: UserID, generation: UInt64) -> Bool {
        activateAccount(activationToken(ownerID: ownerID, generation: generation))
    }

    private func finishOwnerOperation(_ key: Key) {
        lock.lock()
        let remaining = max(0, ownerOperations[key, default: 0] - 1)
        if remaining == 0 { ownerOperations.removeValue(forKey: key) }
        else { ownerOperations[key] = remaining }
        let waiters = remaining == 0 ? operationWaiters.removeValue(forKey: key) ?? [] : []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func finishBookMaterialization(_ key: BookKey, ownerKey: Key, token: BookMaterializationToken) {
        lock.lock()
        var bookWaiters: [CheckedContinuation<Void, Never>] = []
        var recoveryWaiters: [CheckedContinuation<Bool, Never>] = []
        if var active = activeBookAttempts[key], active.token == token {
            active.count -= 1
            if active.count <= 0 {
                activeBookAttempts.removeValue(forKey: key)
                bookWaiters = bookAttemptWaiters.removeValue(forKey: key) ?? []
                if active.recoveryOwned {
                    recoveryWaiters = Array((recoveryClaimWaiters.removeValue(forKey: key) ?? [:]).values)
                }
            }
            else { activeBookAttempts[key] = active }
        }
        let ownerRemaining = max(0, ownerOperations[ownerKey, default: 0] - 1)
        if ownerRemaining == 0 { ownerOperations.removeValue(forKey: ownerKey) }
        else { ownerOperations[ownerKey] = ownerRemaining }
        let waiters = ownerRemaining == 0 ? operationWaiters.removeValue(forKey: ownerKey) ?? [] : []
        lock.unlock()
        bookWaiters.forEach { $0.resume() }
        recoveryWaiters.forEach { $0.resume(returning: true) }
        waiters.forEach { $0.resume() }
    }

    private func finishBookRegistration(_ key: BookKey, ownerKey: Key) {
        lock.lock()
        let count = max(0, bookRegistrations[key, default: 0] - 1)
        if count == 0 { bookRegistrations.removeValue(forKey: key) }
        else { bookRegistrations[key] = count }
        let registrationCount = max(0, ownerRegistrationAdmissions[ownerKey, default: 0] - 1)
        if registrationCount == 0 { ownerRegistrationAdmissions.removeValue(forKey: ownerKey) }
        else { ownerRegistrationAdmissions[ownerKey] = registrationCount }
        let ownerRemaining = max(0, ownerOperations[ownerKey, default: 0] - 1)
        if ownerRemaining == 0 { ownerOperations.removeValue(forKey: ownerKey) }
        else { ownerOperations[ownerKey] = ownerRemaining }
        let waiters = ownerRemaining == 0 ? operationWaiters.removeValue(forKey: ownerKey) ?? [] : []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func permitRecoveryAttempt(_ key: BookKey, claimID: UUID, token: BookMaterializationToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let rollbackLeaseID = recoveryClaims[key]?.rollbackLeaseID
        let rollbackLeaseIsCurrent: Bool
        if let rollbackLeaseID, let lease = provisionalRollbackLeases[key] {
            rollbackLeaseIsCurrent = lease.id == rollbackLeaseID && deletionRetirementWitnesses[key] == lease.witness
        } else {
            rollbackLeaseIsCurrent = false
        }
        guard token.ownerID == key.ownerID, token.accountGeneration == key.generation, token.bookID == key.bookID,
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil,
              var claim = recoveryClaims[key], claim.id == claimID,
              claim.databaseSuccessorToken.map({ $0 == token }) ?? true,
              claim.permittedAttempt == nil || claim.permittedAttempt == token else { return false }
        claim.permittedAttempt = token
        recoveryClaims[key] = claim
        return true
    }

    private func makeRecoveryFailurePermit(_ key: BookKey, claimID: UUID, token: BookMaterializationToken) -> BookImportRecoverySourceFailurePermit? {
        lock.lock()
        let rollbackLeaseID = recoveryClaims[key]?.rollbackLeaseID
        let rollbackLeaseIsCurrent: Bool
        if let rollbackLeaseID, let lease = provisionalRollbackLeases[key] {
            rollbackLeaseIsCurrent = lease.id == rollbackLeaseID && deletionRetirementWitnesses[key] == lease.witness
        } else {
            rollbackLeaseIsCurrent = false
        }
        guard let claim = recoveryClaims[key], claim.id == claimID,
              claim.permittedAttempt.map({ $0 == token }) ?? (claim.expectedToken == token),
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil, !transitioningOwners.contains(key.ownerID),
              !fenced.contains(Key(ownerID: key.ownerID, generation: key.generation)) else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        let epoch = sourceRegistry.bookAttemptEpochSynchronously(ownerID: key.ownerID, generation: key.generation, bookID: key.bookID)
        return BookImportRecoverySourceFailurePermit(ownerID: key.ownerID, generation: key.generation, bookID: key.bookID, token: token, attemptEpoch: epoch)
    }

    private func drainRecoveryAttempt(_ token: BookMaterializationToken) async {
        await drainBookMaterializations(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        await promotionMutex.drainBook(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        await drainBookWork(token.ownerID, token.accountGeneration, token.bookID)
    }

    func failPendingBookSource(book: Book, permit: BookImportRecoverySourceFailurePermit) async -> Bool {
        guard book.userId == permit.ownerID, book.id == permit.bookID else { return false }
        return await sourceRegistry.failRecoveryWaiters(for: book, permit: permit, error: BookSourceRegistryError.unavailable)
    }

    private func releaseRecoveryClaim(_ key: BookKey, ownerKey: Key, claimID: UUID) {
        lock.lock()
        guard recoveryClaims[key]?.id == claimID else { lock.unlock(); return }
        recoveryClaims.removeValue(forKey: key)
        let recoveryWaiters = Array((recoveryClaimWaiters.removeValue(forKey: key) ?? [:]).values)
        let remaining = max(0, ownerOperations[ownerKey, default: 0] - 1)
        if remaining == 0 { ownerOperations.removeValue(forKey: ownerKey) }
        else { ownerOperations[ownerKey] = remaining }
        let waiters = remaining == 0 ? operationWaiters.removeValue(forKey: ownerKey) ?? [] : []
        lock.unlock()
        recoveryWaiters.forEach { $0.resume(returning: true) }
        waiters.forEach { $0.resume() }
    }

    private func cancelBookRecoveryWaiter(_ key: BookKey, waiterID: UUID) {
        lock.lock()
        let continuation = recoveryClaimWaiters[key]?.removeValue(forKey: waiterID)
        if recoveryClaimWaiters[key]?.isEmpty == true {
            recoveryClaimWaiters.removeValue(forKey: key)
        }
        lock.unlock()
        continuation?.resume(returning: false)
    }

    /// Atomically replaces a recovery claim with an active per-book materialization
    /// lease. The lease keeps deletion/account drains blocked through the copy,
    /// while unrelated books can enter the owner generation immediately.
    private func promoteRecoveryAttempt(
        _ key: BookKey,
        ownerKey: Key,
        claimID: UUID,
        token: BookMaterializationToken
    ) -> BookImportMaterializationAdmission? {
        lock.lock()
        let rollbackLeaseID = recoveryClaims[key]?.rollbackLeaseID
        let rollbackLeaseIsCurrent: Bool
        if let rollbackLeaseID, let lease = provisionalRollbackLeases[key] {
            rollbackLeaseIsCurrent = lease.id == rollbackLeaseID && deletionRetirementWitnesses[key] == lease.witness
        } else {
            rollbackLeaseIsCurrent = false
        }
        guard token.ownerID == key.ownerID,
              token.accountGeneration == key.generation,
              token.bookID == key.bookID,
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil,
              !transitioningOwners.contains(key.ownerID),
              !fenced.contains(ownerKey),
              (!retiredBooks.contains(key) || rollbackLeaseIsCurrent) && sourceReplacements[key] == nil,
              !retiredBookAttempts.contains(token),
              recoveryClaims[key]?.id == claimID,
              recoveryClaims[key]?.permittedAttempt == token,
              activeBookAttempts[key] == nil else {
            lock.unlock()
            return nil
        }
        let claim = recoveryClaims[key]
        let expectedPrior = claim?.expectedToken
        let successor = claim?.databaseSuccessorToken
        if let latest = latestBookAttemptTokens[key], latest != expectedPrior,
           !(latest == successor && successor == token) {
            lock.unlock()
            return nil
        }
        recoveryClaims.removeValue(forKey: key)
        activeBookAttempts[key] = ActiveBookAttempt(token: token, count: 1, recoveryOwned: true, rollbackLeaseID: rollbackLeaseID)
        latestBookAttemptTokens[key] = token
        lock.unlock()
        return BookImportMaterializationAdmission(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID) { [weak self] in
            self?.finishBookMaterialization(key, ownerKey: ownerKey, token: token)
        }
    }

    private func drainBookMaterializations(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        await withCheckedContinuation { continuation in
            lock.lock()
            guard (activeBookAttempts[key]?.count ?? 0) > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            bookAttemptWaiters[key, default: []].append(continuation)
            lock.unlock()
        }
    }

    func hasBookAttemptDrainWaiterForTesting(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock(); defer { lock.unlock() }
        return !bookAttemptWaiters[key, default: []].isEmpty
    }

    private func isFenced(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fenced.contains(key)
    }

    private func drainOwnerOperations(ownerID: UserID, generation: UInt64) async {
        let key = Key(ownerID: ownerID, generation: generation)
        await withCheckedContinuation { continuation in
            lock.lock()
            guard ownerOperations[key, default: 0] > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            operationWaiters[key, default: []].append(continuation)
            lock.unlock()
        }
    }
}

private final class BookPromotionMutex: @unchecked Sendable {
    private struct OwnerKey: Hashable {
        let ownerID: UserID
        let generation: UInt64
    }

    private struct BookKey: Hashable {
        let ownerID: UserID
        let generation: UInt64
        let bookID: BookID
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<BookPromotionPermit, any Error>
    }

    private struct State {
        var held = false
        var retired = false
        var attemptID: UUID?
        var waiters: [Waiter] = []
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var states: [BookKey: State] = [:]
    private var retiredOwners = Set<OwnerKey>()
    private var retiredBooks = Set<BookKey>()
    private var waiterKeys: [UUID: BookKey] = [:]

    func acquire(_ token: BookMaterializationToken) async throws -> BookPromotionPermit {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        let waiterID = UUID()
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(key: key, attemptID: token.attemptID, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { self.cancel(waiterID: waiterID) }
        }
        if Task.isCancelled {
            permit.release()
            throw CancellationError()
        }
        return permit
    }

    func activateAttempt(_ token: BookMaterializationToken, reopenRetiredBookFence: Bool = true) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        defer { lock.unlock() }
        guard !retiredOwners.contains(OwnerKey(ownerID: token.ownerID, generation: token.accountGeneration)) else { return false }
        guard reopenRetiredBookFence || !retiredBooks.contains(key) else { return false }
        guard var state = states[key], !state.held, state.waiters.isEmpty else {
            if states[key] == nil {
                states[key] = State(attemptID: token.attemptID)
                if reopenRetiredBookFence { retiredBooks.remove(key) }
                return true
            }
            return false
        }
        state.retired = false
        state.attemptID = token.attemptID
        states[key] = state
        if reopenRetiredBookFence { retiredBooks.remove(key) }
        return true
    }

    func retireAttempt(_ token: BookMaterializationToken) {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        guard states[key]?.attemptID == token.attemptID else { lock.unlock(); return }
        lock.unlock()
        retire(keys: [key], bookKey: nil)
    }

    func retireBook(ownerID: UserID, generation: UInt64, bookID: BookID) {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        retire(keys: [key], bookKey: key)
    }

    func restoreBook(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[key], !state.held, state.waiters.isEmpty else {
            if states[key] == nil {
                states[key] = State(attemptID: UUID())
                retiredBooks.remove(key)
                return true
            }
            return false
        }
        state.retired = false
        state.attemptID = nil
        states[key] = state
        retiredBooks.remove(key)
        return true
    }

    func retireOwner(ownerID: UserID, generation: UInt64) {
        let ownerKey = OwnerKey(ownerID: ownerID, generation: generation)
        lock.lock()
        retiredOwners.insert(ownerKey)
        let keys = states.keys.filter { $0.ownerID == ownerID && $0.generation == generation }
        lock.unlock()
        retire(keys: Array(keys), bookKey: nil)
    }

    func drainBook(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        await waitUntilDrained(key)
    }

    func isDrained(_ token: BookMaterializationToken) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock(); defer { lock.unlock() }
        guard let state = states[key] else { return true }
        return !state.held && state.waiters.isEmpty
    }

    func drainOwner(ownerID: UserID, generation: UInt64) async {
        let keys = keys(ownerID: ownerID, generation: generation)
        for key in keys { await waitUntilDrained(key) }
    }

    private func keys(ownerID: UserID, generation: UInt64) -> [BookKey] {
        lock.lock(); defer { lock.unlock() }
        return states.keys.filter { $0.ownerID == ownerID && $0.generation == generation }
    }

    private func enqueue(
        key: BookKey,
        attemptID: UUID,
        waiterID: UUID,
        continuation: CheckedContinuation<BookPromotionPermit, any Error>
    ) {
        var immediate: BookPromotionPermit?
        var error: (any Error)?
        lock.lock()
        var state = states[key] ?? State()
        if retiredOwners.contains(OwnerKey(ownerID: key.ownerID, generation: key.generation)) || retiredBooks.contains(key) || state.retired {
            error = BookImportPromotionError.retired
        } else if let currentAttempt = state.attemptID, currentAttempt != attemptID {
            error = BookImportPromotionError.staleAttempt
        } else {
            state.attemptID = attemptID
            if !state.held {
                state.held = true
                immediate = BookPromotionPermit { [weak self] in self?.release(key) }
            } else {
                state.waiters.append(Waiter(id: waiterID, continuation: continuation))
                waiterKeys[waiterID] = key
            }
            states[key] = state
        }
        lock.unlock()
        if let error { continuation.resume(throwing: error) }
        else if let immediate { continuation.resume(returning: immediate) }
    }

    private func cancel(waiterID: UUID) {
        lock.lock()
        guard let key = waiterKeys.removeValue(forKey: waiterID), var state = states[key],
              let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else {
            lock.unlock()
            return
        }
        let waiter = state.waiters.remove(at: index)
        let drained = !state.held && state.waiters.isEmpty ? state.drainWaiters : []
        if !drained.isEmpty { state.drainWaiters.removeAll() }
        states[key] = state
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
        drained.forEach { $0.resume() }
    }

    private func retire(keys: [BookKey], bookKey: BookKey?) {
        var cancelled: [Waiter] = []
        var drained: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let bookKey { retiredBooks.insert(bookKey) }
        for key in keys {
            guard var state = states[key] else { continue }
            state.retired = true
            cancelled.append(contentsOf: state.waiters)
            state.waiters.forEach { waiterKeys.removeValue(forKey: $0.id) }
            state.waiters.removeAll()
            if !state.held {
                drained.append(contentsOf: state.drainWaiters)
                state.drainWaiters.removeAll()
            }
            states[key] = state
        }
        lock.unlock()
        cancelled.forEach { $0.continuation.resume(throwing: BookImportPromotionError.retired) }
        drained.forEach { $0.resume() }
    }

    private func release(_ key: BookKey) {
        var next: Waiter?
        var drained: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        guard var state = states[key], state.held else { lock.unlock(); return }
        if !state.retired, !state.waiters.isEmpty {
            next = state.waiters.removeFirst()
            if let next { waiterKeys.removeValue(forKey: next.id) }
        } else {
            state.held = false
            if state.waiters.isEmpty {
                drained = state.drainWaiters
                state.drainWaiters.removeAll()
            }
        }
        states[key] = state
        lock.unlock()
        if let next {
            next.continuation.resume(returning: BookPromotionPermit { [weak self] in self?.release(key) })
        }
        drained.forEach { $0.resume() }
    }

    private func waitUntilDrained(_ key: BookKey) async {
        await withCheckedContinuation { continuation in registerDrainWaiter(key, continuation: continuation) }
    }

    private func registerDrainWaiter(_ key: BookKey, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard var state = states[key], state.held || !state.waiters.isEmpty else {
            lock.unlock()
            continuation.resume()
            return
        }
        state.drainWaiters.append(continuation)
        states[key] = state
        lock.unlock()
    }
}

private final class BookPromotionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) { releaseBody = release }

    func release() {
        lock.lock()
        let body = releaseBody
        releaseBody = nil
        lock.unlock()
        body?()
    }

    deinit { release() }
}

public final class BookImportOperationLease: @unchecked Sendable {
    public let generation: UInt64
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    fileprivate init(generation: UInt64, release: @escaping @Sendable () -> Void) {
        self.generation = generation
        releaseBody = release
    }

    public func release() {
        lock.lock()
        let release = releaseBody
        releaseBody = nil
        lock.unlock()
        release?()
    }

    deinit { release() }
}

/// Exclusive owner-operation lease for replacing one retryable attempt.
/// Draining is token-scoped and activation transfers the claim's account
/// operation into exactly one materialization admission.
public final class BookImportRetryClaim: @unchecked Sendable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    private let retiring: BookMaterializationToken
    private let lock = NSLock()
    private var drainBody: (@Sendable () async -> RetiredBookMaterializationAttempt)?
    private var activateBody: (@Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?)?
    private var releaseBody: (@Sendable () -> Void)?
    private var drainTask: Task<RetiredBookMaterializationAttempt, Never>?
    private var drainCompleted = false

    fileprivate init(ownerID: UserID, generation: UInt64, bookID: BookID, retiring: BookMaterializationToken,
                     drain: @escaping @Sendable () async -> RetiredBookMaterializationAttempt,
                     activate: @escaping @Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?,
                     release: @escaping @Sendable () -> Void) {
        self.ownerID = ownerID
        self.generation = generation
        self.bookID = bookID
        self.retiring = retiring
        drainBody = drain
        activateBody = activate
        releaseBody = release
    }

    public func drain() async -> RetiredBookMaterializationAttempt {
        let task = lock.withLock { () -> Task<RetiredBookMaterializationAttempt, Never> in
            if let drainTask { return drainTask }
            let body = drainBody ?? { RetiredBookMaterializationAttempt(token: self.retiring) }
            let task = Task { await body() }
            drainTask = task
            return task
        }
        let result = await task.value
        lock.withLock { drainCompleted = true }
        return result
    }

    public func activate(_ token: BookMaterializationToken) -> BookImportMaterializationAdmission? {
        let body = lock.withLock { drainCompleted ? activateBody : nil }
        guard let body else { return nil }
        let admission = body(token)
        guard admission != nil else { return nil }
        lock.lock()
        let release = releaseBody
        releaseBody = nil
        drainBody = nil
        activateBody = nil
        lock.unlock()
        release?()
        return admission
    }

    public func release() {
        lock.lock()
        let release = releaseBody
        releaseBody = nil
        drainBody = nil
        activateBody = nil
        lock.unlock()
        release?()
    }

    deinit { release() }
}

public final class BookImportRecoveryClaim: @unchecked Sendable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    private let lock = NSLock()
    private var allowAttemptBody: (@Sendable (BookMaterializationToken) -> Bool)?
    private var promoteAttemptBody: (@Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?)?
    private var drainPriorAttemptBody: (@Sendable () async -> Void)?
    private var makeFailurePermitBody: (@Sendable (BookMaterializationToken) -> BookImportRecoverySourceFailurePermit?)?
    private var recordDatabaseSuccessorBody: (@Sendable (BookMaterializationToken, BookImportProvisionalRollbackLease) -> Bool)?
    private var recordPausedAttemptBody: (@Sendable (BookMaterializationToken, BookImportProvisionalRollbackLease) -> Bool)?
    private var releaseBody: (@Sendable () -> Void)?

    fileprivate init(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        drainPriorAttempt: @escaping @Sendable () async -> Void,
        allowAttempt: @escaping @Sendable (BookMaterializationToken) -> Bool,
        promoteAttempt: @escaping @Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?,
        makeFailurePermit: @escaping @Sendable (BookMaterializationToken) -> BookImportRecoverySourceFailurePermit?,
        recordDatabaseSuccessor: @escaping @Sendable (BookMaterializationToken, BookImportProvisionalRollbackLease) -> Bool,
        recordPausedAttempt: @escaping @Sendable (BookMaterializationToken, BookImportProvisionalRollbackLease) -> Bool,
        release: @escaping @Sendable () -> Void
    ) {
        self.ownerID = ownerID
        self.generation = generation
        self.bookID = bookID
        drainPriorAttemptBody = drainPriorAttempt
        allowAttemptBody = allowAttempt
        promoteAttemptBody = promoteAttempt
        makeFailurePermitBody = makeFailurePermit
        recordDatabaseSuccessorBody = recordDatabaseSuccessor
        recordPausedAttemptBody = recordPausedAttempt
        releaseBody = release
    }

    public func drainPriorAttempt() async {
        let body = lock.withLock { drainPriorAttemptBody }
        await body?()
    }

    public func allowMaterialization(_ token: BookMaterializationToken) -> Bool {
        lock.lock()
        let body = allowAttemptBody
        lock.unlock()
        return body?(token) ?? false
    }

    func sourceFailurePermit(for token: BookMaterializationToken) -> BookImportRecoverySourceFailurePermit? {
        lock.lock()
        let body = makeFailurePermitBody
        lock.unlock()
        return body?(token)
    }

    /// Records the exact token returned by a successful DB recovery CAS. This
    /// synchronous bookkeeping intentionally runs even if cancellation arrived
    /// during the CAS await, so a later retry can follow the committed token.
    public func recordDatabaseSuccessor(
        _ token: BookMaterializationToken,
        lease: BookImportProvisionalRollbackLease
    ) -> Bool {
        lock.lock()
        let body = recordDatabaseSuccessorBody
        lock.unlock()
        return body?(token, lease) ?? false
    }

    public func recordPausedAttempt(_ token: BookMaterializationToken, lease: BookImportProvisionalRollbackLease) -> Bool {
        lock.lock()
        let body = recordPausedAttemptBody
        lock.unlock()
        return body?(token, lease) ?? false
    }

    /// Transfers the claim's account-drain operation into an active attempt
    /// lease and releases the recovery claim atomically.
    public func promoteMaterialization(_ token: BookMaterializationToken) -> BookImportMaterializationAdmission? {
        lock.lock()
        let body = promoteAttemptBody
        lock.unlock()
        let admission = body?(token)
        if admission != nil { release() }
        return admission
    }

    public func release() {
        lock.lock()
        let body = releaseBody
        releaseBody = nil
        allowAttemptBody = nil
        promoteAttemptBody = nil
        drainPriorAttemptBody = nil
        makeFailurePermitBody = nil
        recordDatabaseSuccessorBody = nil
        recordPausedAttemptBody = nil
        lock.unlock()
        body?()
    }

    deinit { release() }
}

public final class BookImportMaterializationAdmission: @unchecked Sendable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    fileprivate init(ownerID: UserID, generation: UInt64, bookID: BookID, release: @escaping @Sendable () -> Void) {
        self.ownerID = ownerID
        self.generation = generation
        self.bookID = bookID
        releaseBody = release
    }

    public func admits(_ token: BookMaterializationToken) -> Bool {
        ownerID == token.ownerID && generation == token.accountGeneration && bookID == token.bookID
    }

    public func release() {
        lock.lock()
        let body = releaseBody
        releaseBody = nil
        lock.unlock()
        body?()
    }

    deinit { release() }
}
