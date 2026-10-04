import Foundation

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
    }

    private struct RecoveryClaimState {
        let id: UUID
        var permittedAttempt: BookMaterializationToken?
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
    private var retiredBooks = Set<BookKey>()
    private var retiredBookAttempts = Set<BookMaterializationToken>()
    private var latestBookAttemptTokens: [BookKey: BookMaterializationToken] = [:]
    private var recoveryClaims: [BookKey: RecoveryClaimState] = [:]
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
        retiredBooks.insert(key)
        if let token = activeBookAttempts[key]?.token ?? latestBookAttemptTokens[key] {
            retiredBookAttempts.insert(token)
        }
        lock.unlock()
        promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
        sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
        cancelBookWork(ownerID, generation, bookID)
    }

    public func drainBook(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
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
    public func restoreBookAfterFailedRetirement(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        retiredToken: BookMaterializationToken? = nil
    ) async -> Bool {
        await promotionMutex.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        await sourceRegistry.drainBook(ownerID: ownerID, generation: generation, bookID: bookID)
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        let canRestore = lock.withLock {
            let latestToken = latestBookAttemptTokens[key]
            let retiredAttemptMatches: Bool
            if let retiredToken {
                retiredAttemptMatches = latestToken == retiredToken && retiredBookAttempts.contains(retiredToken)
            } else {
                retiredAttemptMatches = latestToken.map(retiredBookAttempts.contains) ?? true
            }
            return retiredBooks.contains(key)
                && activeBookAttempts[key] == nil
                && retiredAttemptMatches
                && (retiredToken == nil || (retiredToken?.ownerID == ownerID
                    && retiredToken?.accountGeneration == generation
                    && retiredToken?.bookID == bookID))
        }
        guard canRestore,
              sourceRegistry.activateBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID) else { return false }
        let promotionRestored = retiredToken.map(promotionMutex.activateAttempt) ?? promotionMutex.restoreBook(ownerID: ownerID, generation: generation, bookID: bookID)
        guard promotionRestored else {
            sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
            return false
        }
        let didRestore = lock.withLock {
            guard retiredBooks.contains(key), activeBookAttempts[key] == nil else { return false }
            retiredBooks.remove(key)
            return true
        }
        guard didRestore else {
            sourceRegistry.fenceBookSynchronously(ownerID: ownerID, generation: generation, bookID: bookID)
            promotionMutex.retireBook(ownerID: ownerID, generation: generation, bookID: bookID)
            return false
        }
        return true
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
    public func admitBookMaterialization(_ token: BookMaterializationToken) -> BookImportMaterializationAdmission? {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        guard !transitioningOwners.contains(token.ownerID),
              !fenced.contains(Key(ownerID: token.ownerID, generation: token.accountGeneration)),
              !retiredBooks.contains(key) else {
            lock.unlock()
            return nil
        }
        if let claim = recoveryClaims.first(where: { $0.key.ownerID == token.ownerID && $0.key.bookID == token.bookID })?.value,
           claim.permittedAttempt != token {
            lock.unlock()
            return nil
        }
        if var active = activeBookAttempts[key] {
            guard active.token == token, !retiredBookAttempts.contains(token) else {
                lock.unlock()
                return nil
            }
            active.count += 1
            activeBookAttempts[key] = active
        } else {
            guard !retiredBookAttempts.contains(token) else {
                lock.unlock()
                return nil
            }
            activeBookAttempts[key] = ActiveBookAttempt(token: token, count: 1, recoveryOwned: false)
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
              !retiredBooks.contains(key),
              recoveryClaims[key] == nil,
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
    public func claimBookRecovery(ownerID: UserID, generation: UInt64, bookID: BookID) -> BookImportRecoveryClaim? {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        let id = UUID()
        lock.lock()
        let hasActiveAttempt = activeBookAttempts.contains { $0.key.ownerID == ownerID && $0.key.bookID == bookID && $0.value.count > 0 }
        let hasRegistration = bookRegistrations.contains { $0.key.ownerID == ownerID && $0.key.bookID == bookID && $0.value > 0 }
        let hasOwnerRegistration = ownerRegistrationAdmissions[Key(ownerID: ownerID, generation: generation), default: 0] > 0
        let hasRecoveryClaim = recoveryClaims.keys.contains { $0.ownerID == ownerID && $0.bookID == bookID }
        guard !transitioningOwners.contains(ownerID),
              !fenced.contains(Key(ownerID: ownerID, generation: generation)),
              !retiredBooks.contains(key),
              !hasActiveAttempt,
              !hasRegistration,
              !hasOwnerRegistration,
              !hasRecoveryClaim else {
            lock.unlock()
            return nil
        }
        recoveryClaims[key] = RecoveryClaimState(id: id, permittedAttempt: nil)
        let ownerKey = Key(ownerID: ownerID, generation: generation)
        ownerOperations[ownerKey, default: 0] += 1
        lock.unlock()
        return BookImportRecoveryClaim(ownerID: ownerID, generation: generation, bookID: bookID,
                                       allowAttempt: { [weak self] token in self?.permitRecoveryAttempt(key, claimID: id, token: token) ?? false },
                                       promoteAttempt: { [weak self] token in self?.promoteRecoveryAttempt(key, ownerKey: ownerKey, claimID: id, token: token) },
                                       release: { [weak self] in self?.releaseRecoveryClaim(key, ownerKey: ownerKey, claimID: id) })
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
    public func activatePromotionAttempt(_ token: BookMaterializationToken) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        let isRetired = retiredBooks.contains(key)
        let tokenRetired = retiredBookAttempts.contains(token)
        lock.unlock()
        guard !isRetired, !tokenRetired else { return false }
        guard admits(ownerID: token.ownerID, generation: token.accountGeneration) else { return false }
        guard promotionMutex.activateAttempt(token) else { return false }
        guard sourceRegistry.activateBookSynchronously(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID) else {
            promotionMutex.retireBook(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
            return false
        }
        return true
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
        guard token.ownerID == key.ownerID, token.accountGeneration == key.generation, token.bookID == key.bookID,
              !retiredBooks.contains(key),
              var claim = recoveryClaims[key], claim.id == claimID else { return false }
        claim.permittedAttempt = token
        recoveryClaims[key] = claim
        return true
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
        guard token.ownerID == key.ownerID,
              token.accountGeneration == key.generation,
              token.bookID == key.bookID,
              !retiredBooks.contains(key),
              !transitioningOwners.contains(key.ownerID),
              !fenced.contains(ownerKey),
              !retiredBooks.contains(key),
              recoveryClaims[key]?.id == claimID,
              activeBookAttempts[key] == nil else {
            lock.unlock()
            return nil
        }
        recoveryClaims.removeValue(forKey: key)
        activeBookAttempts[key] = ActiveBookAttempt(token: token, count: 1, recoveryOwned: true)
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

    func activateAttempt(_ token: BookMaterializationToken) -> Bool {
        let key = BookKey(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID)
        lock.lock()
        defer { lock.unlock() }
        guard !retiredOwners.contains(OwnerKey(ownerID: token.ownerID, generation: token.accountGeneration)) else { return false }
        guard var state = states[key], !state.held, state.waiters.isEmpty else {
            if states[key] == nil {
                states[key] = State(attemptID: token.attemptID)
                retiredBooks.remove(key)
                return true
            }
            return false
        }
        state.retired = false
        state.attemptID = token.attemptID
        states[key] = state
        retiredBooks.remove(key)
        return true
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

public final class BookImportRecoveryClaim: @unchecked Sendable {
    public let ownerID: UserID
    public let generation: UInt64
    public let bookID: BookID
    private let lock = NSLock()
    private var allowAttemptBody: (@Sendable (BookMaterializationToken) -> Bool)?
    private var promoteAttemptBody: (@Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?)?
    private var releaseBody: (@Sendable () -> Void)?

    fileprivate init(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        allowAttempt: @escaping @Sendable (BookMaterializationToken) -> Bool,
        promoteAttempt: @escaping @Sendable (BookMaterializationToken) -> BookImportMaterializationAdmission?,
        release: @escaping @Sendable () -> Void
    ) {
        self.ownerID = ownerID
        self.generation = generation
        self.bookID = bookID
        allowAttemptBody = allowAttempt
        promoteAttemptBody = promoteAttempt
        releaseBody = release
    }

    public func allowMaterialization(_ token: BookMaterializationToken) -> Bool {
        lock.lock()
        let body = allowAttemptBody
        lock.unlock()
        return body?(token) ?? false
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
