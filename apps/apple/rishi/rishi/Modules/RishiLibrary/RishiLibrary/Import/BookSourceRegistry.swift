import Foundation

private final class BookSourceRegistryFence: @unchecked Sendable {
    struct Key: Hashable {
        let ownerID: UserID
        let generation: UInt64
    }
    struct BookKey: Hashable {
        let ownerID: UserID
        let generation: UInt64
        let bookID: BookID
    }
    struct Record {
        let ownerID: UserID
        let generation: UInt64
        let bookID: BookID
        let authority: BookSourceEffectAuthority
        let permit: BookSourceAccessPermit
        let invalidation: BookSourceInvalidationSignal
        let lifetime: BookSourceOwnerLifetime
    }

    private let lock = NSLock()
    private var owners = Set<Key>()
    private var transitioningOwners = Set<UserID>()
    private var transitionEpochs: [UserID: UInt64] = [:]
    private var retiredBooks = Set<BookKey>()
    private var bookAttemptEpochs: [BookKey: UInt64] = [:]
    private var authorities: [UUID: Record] = [:]

    func register(ownerID: UserID, generation: UInt64, bookID: BookID, authority: BookSourceEffectAuthority, permit: BookSourceAccessPermit, invalidation: BookSourceInvalidationSignal, lifetime: BookSourceOwnerLifetime) throws {
        lock.lock(); defer { lock.unlock() }
        let key = Key(ownerID: ownerID, generation: generation)
        let bookKey = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        guard !transitioningOwners.contains(ownerID), !owners.contains(key), !retiredBooks.contains(bookKey) else { throw BookSourceRegistryError.accountRevoked }
        authorities[permit.sourceInstanceID] = Record(ownerID: ownerID, generation: generation, bookID: bookID, authority: authority, permit: permit, invalidation: invalidation, lifetime: lifetime)
    }

    func fence(ownerID: UserID, generation: UInt64) {
        lock.lock()
        owners.insert(Key(ownerID: ownerID, generation: generation))
        let owned = authorities.values.filter { $0.ownerID == ownerID && $0.generation == generation }
        lock.unlock()
        owned.forEach { $0.authority.closeAdmission($0.permit) }
        owned.forEach { $0.invalidation.invalidate() }
    }

    func fenceOwnerTransition(ownerID: UserID) -> UInt64 {
        lock.lock()
        transitioningOwners.insert(ownerID)
        let epoch = transitionEpochs[ownerID, default: 0] &+ 1
        transitionEpochs[ownerID] = epoch
        let owned = authorities.values.filter { $0.ownerID == ownerID }
        lock.unlock()
        owned.forEach { $0.authority.closeAdmission($0.permit) }
        owned.forEach { $0.invalidation.invalidate() }
        return epoch
    }

    func unfence(ownerID: UserID, generation: UInt64, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard transitionEpochs[ownerID, default: 0] == epoch else { return false }
        transitioningOwners.remove(ownerID)
        owners.remove(Key(ownerID: ownerID, generation: generation))
        retiredBooks = retiredBooks.filter { $0.ownerID != ownerID || $0.generation != generation }
        return true
    }

    func isOwnerTransitioning(_ ownerID: UserID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transitioningOwners.contains(ownerID)
    }

    func transitionEpoch(ownerID: UserID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return transitionEpochs[ownerID, default: 0]
    }

    func fenceBook(ownerID: UserID, generation: UInt64, bookID: BookID) {
        lock.lock()
        retiredBooks.insert(BookKey(ownerID: ownerID, generation: generation, bookID: bookID))
        let matching = authorities.values.filter { $0.bookID == bookID && $0.ownerID == ownerID && $0.generation == generation }
        lock.unlock()
        matching.forEach { $0.authority.closeAdmission($0.permit) }
        matching.forEach { $0.invalidation.invalidate() }
    }

    func activateBook(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !transitioningOwners.contains(ownerID),
              !owners.contains(Key(ownerID: ownerID, generation: generation)) else { return false }
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        retiredBooks.remove(key)
        bookAttemptEpochs[key, default: 0] &+= 1
        return true
    }

    func bookAttemptEpoch(ownerID: UserID, generation: UInt64, bookID: BookID) -> UInt64 {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        lock.lock(); defer { lock.unlock() }
        return bookAttemptEpochs[key, default: 0]
    }

    func isFenced(ownerID: UserID, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owners.contains(Key(ownerID: ownerID, generation: generation))
    }

    func isBookRetired(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return retiredBooks.contains(BookKey(ownerID: ownerID, generation: generation, bookID: bookID))
    }

    func records(ownerID: UserID, generation: UInt64, bookID: BookID? = nil) -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return authorities.values.filter {
            $0.ownerID == ownerID && $0.generation == generation && (bookID == nil || $0.bookID == bookID)
        }
    }

    func release(_ permit: BookSourceAccessPermit) {
        lock.lock()
        let record = authorities[permit.sourceInstanceID]
        lock.unlock()
        guard let record else { return }
        record.authority.closeAdmission(permit)
        Task { [weak self] in
            await record.authority.drain(permit)
            self?.remove(permit)
        }
    }

    private func remove(_ permit: BookSourceAccessPermit) {
        lock.lock(); defer { lock.unlock() }
        authorities.removeValue(forKey: permit.sourceInstanceID)
    }

    func unregister(_ permit: BookSourceAccessPermit) { remove(permit) }
}

public enum BookSourceRegistryError: Error, Sendable, Equatable {
    case unavailable
    case accountRevoked
    case managedSourceUnavailable
}

/// Owns the currently readable source for each canonical BookID. Promotion is
/// a future-resolution change; leases already handed to a reader keep their
/// immutable URL and source permit until their final reference is released.
public actor BookSourceRegistry: BookSourceResolving {
    private struct Entry {
        let bookID: BookID
        let ownerID: UserID
        let generation: UInt64
        let owner: BookSourceOwner
        let isPreview: Bool
        let token: BookMaterializationToken?
        var isPublished: Bool
        var invalidated = false
    }

    private struct ManagedWaiter {
        let book: Book
        let generation: UInt64
        let continuation: CheckedContinuation<ManagedBookSource, Error>
    }

    private struct TerminalFailure {
        let error: any Error
        let attemptEpoch: UInt64
    }

    private struct BookKey: Hashable {
        let ownerID: UserID
        let generation: UInt64
        let bookID: BookID
    }

    private let persistence: (any BookImportPersistence)?
    private let managedURL: @Sendable (Book) -> URL?
    private let currentGeneration: @Sendable () async -> UInt64
    private let currentOwnerID: @Sendable () async -> UserID?
    private var entries: [BookID: Entry] = [:]
    private var activeTransientLeaseCounts: [BookMaterializationToken: Int] = [:]
    private var waiters: [UUID: ManagedWaiter] = [:]
    private var terminalFailures: [BookKey: TerminalFailure] = [:]
    private nonisolated let synchronousFence = BookSourceRegistryFence()

    public init(
        persistence: (any BookImportPersistence)? = nil,
        currentGeneration: @escaping @Sendable () async -> UInt64,
        currentOwnerID: @escaping @Sendable () async -> UserID? = { nil },
        managedURL: @escaping @Sendable (Book) -> URL?
    ) {
        self.persistence = persistence
        self.currentGeneration = currentGeneration
        self.currentOwnerID = currentOwnerID
        self.managedURL = managedURL
    }

    public func registerSource(
        for book: Book,
        url: URL,
        accountGeneration: UInt64,
        contentRevision: UUID,
        token: BookMaterializationToken? = nil,
        requiresSecurityScope: Bool = true,
        observeChanges: Bool = true,
        published: Bool = true,
        onOwnerReleased: (@Sendable () -> Void)? = nil
    ) async throws -> BookSourceAccessPermit {
        guard await currentOwnerID() == book.userId, await currentGeneration() == accountGeneration else {
            throw BookSourceRegistryError.accountRevoked
        }
        guard !synchronousFence.isOwnerTransitioning(book.userId) else { throw BookSourceRegistryError.accountRevoked }
        let bookKey = BookKey(ownerID: book.userId, generation: accountGeneration, bookID: book.id)
        terminalFailures.removeValue(forKey: bookKey)
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        let readingPermit = BookReadingPermit(ownerID: book.userId, accountGeneration: accountGeneration, bookID: book.id, contentRevision: contentRevision)
        let lifetime = BookSourceOwnerLifetime()
        let invalidation = BookSourceInvalidationSignal()
        do {
            try synchronousFence.register(ownerID: book.userId, generation: accountGeneration, bookID: book.id, authority: authority, permit: permit, invalidation: invalidation, lifetime: lifetime)
        } catch {
            authority.closeAdmission(permit)
            await authority.drain(permit)
            lifetime.release()
            throw error
        }
        let owner: BookSourceOwner
        do {
            owner = try BookSourceOwner(url: url, access: .account(readingPermit), sourceAccessPermit: permit, effectAuthority: authority, lifetime: lifetime, invalidation: invalidation, usesSecurityScope: requiresSecurityScope, onRelease: { [weak fence = synchronousFence] in
                fence?.release(permit)
                onOwnerReleased?()
            })
        } catch {
            lifetime.release()
            synchronousFence.release(permit)
            if let token, let persistence {
                for phase in [BookMaterializationPhase.registered, .copying] {
                    if (try? await persistence.transition(token: token, from: phase, to: .paused)) == true { break }
                }
            }
            throw error
        }
        if observeChanges {
            let presenter = BookSourcePresenter(url: url) { [weak authority, weak self] changedURL in
                invalidation.invalidate()
                authority?.closeAdmission(permit)
                Task {
                    await authority?.drain(permit)
                    await self?.presenterInvalidated(bookID: book.id, permit: permit, token: token, changedURL: changedURL)
                }
            } drainBeforeYield: { [weak authority, weak self] in
                invalidation.invalidate()
                authority?.closeAdmission(permit)
                await authority?.drain(permit)
                await self?.presenterInvalidated(bookID: book.id, permit: permit, token: token, changedURL: nil)
            }
            owner.attach(presenter: presenter)
        }
        entries[book.id] = Entry(
            bookID: book.id,
            ownerID: book.userId,
            generation: accountGeneration,
            owner: owner,
            isPreview: false,
            token: token,
            isPublished: published
        )
        return permit
    }

    public func acquireReadableSource(for book: Book) async throws -> BookSourceLease {
        if let managed = try await managedSource(for: book) {
            let permit = BookSourceAccessPermit()
            let authority = BookSourceEffectAuthority()
            authority.register(permit)
            let readingPermit = BookReadingPermit(ownerID: book.userId, accountGeneration: managed.accountGeneration, bookID: book.id, contentRevision: managed.fingerprint.version.materializationRevision)
            let lifetime = BookSourceOwnerLifetime()
            let invalidation = BookSourceInvalidationSignal()
            do {
                try synchronousFence.register(ownerID: book.userId, generation: managed.accountGeneration, bookID: book.id, authority: authority, permit: permit, invalidation: invalidation, lifetime: lifetime)
            } catch {
                authority.closeAdmission(permit)
                await authority.drain(permit)
                lifetime.release()
                throw error
            }
            let owner: BookSourceOwner
            do {
                owner = try BookSourceOwner(url: managed.url, access: .account(readingPermit), sourceAccessPermit: permit, effectAuthority: authority, lifetime: lifetime, invalidation: invalidation, onRelease: { [weak fence = synchronousFence] in fence?.release(permit) })
            } catch {
                lifetime.release()
                synchronousFence.release(permit)
                throw error
            }
            return BookSourceLease(owner: owner, cachePolicy: .managed(bookID: book.id, version: managed.fingerprint.version))
        }
        let generation = await currentGeneration()
        if !synchronousFence.isOwnerTransitioning(book.userId),
           !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
           let entry = entries[book.id], entry.ownerID == book.userId, entry.generation == generation,
           entry.isPublished, !entry.invalidated {
            do {
                let admission = try entry.owner.effectAuthority.admit(entry.owner.sourceAccessPermit)
                admission.release()
                if let token = entry.token {
                    activeTransientLeaseCounts[token, default: 0] += 1
                    return BookSourceLease(owner: entry.owner, cachePolicy: .transient) { [weak self] in
                        Task { await self?.releaseTransientLease(token) }
                    }
                }
                return BookSourceLease(owner: entry.owner, cachePolicy: .transient)
            } catch {
                throw BookSourceRegistryError.unavailable
            }
        }
        throw BookSourceRegistryError.unavailable
    }

    /// Prevents any future transient lease from selecting this source before
    /// recovery removes an owned staging directory. The caller must already
    /// have verified a ready managed destination. Existing transient leases
    /// cause cleanup to defer; otherwise the matching entry is removed and
    /// drained before the filesystem path can be deleted.
    public func prepareOwnedSourceCleanup(for token: BookMaterializationToken) async -> Bool {
        guard activeTransientLeaseCounts[token, default: 0] == 0 else { return false }
        guard let entry = entries[token.bookID], entry.token == token else { return true }
        entries.removeValue(forKey: token.bookID)
        entry.owner.invalidation.invalidate()
        entry.owner.effectAuthority.closeAdmission(entry.owner.sourceAccessPermit)
        await entry.owner.effectAuthority.drain(entry.owner.sourceAccessPermit)
        return activeTransientLeaseCounts[token, default: 0] == 0
    }

    private func releaseTransientLease(_ token: BookMaterializationToken) {
        let count = activeTransientLeaseCounts[token, default: 0]
        if count <= 1 { activeTransientLeaseCounts.removeValue(forKey: token) }
        else { activeTransientLeaseCounts[token] = count - 1 }
    }

    /// Makes a verified transient registration visible to readers. Verification
    /// and this exact-permit admission check finish before the actor exposes the
    /// entry through `acquireReadableSource`.
    func publishTransientSource(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        token: BookMaterializationToken,
        permit: BookSourceAccessPermit
    ) -> Bool {
        guard var entry = entries[bookID], entry.ownerID == ownerID,
              entry.generation == generation, entry.token == token,
              entry.owner.sourceAccessPermit == permit,
              entry.isPreview == false, !entry.invalidated, !entry.isPublished else { return false }
        do {
            let admission = try entry.owner.effectAuthority.admit(permit)
            defer { admission.release() }
            entry.isPublished = true
            entries[bookID] = entry
            return true
        } catch {
            return false
        }
    }

    func isPublishedTransientSource(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID,
        token: BookMaterializationToken,
        permit: BookSourceAccessPermit
    ) -> Bool {
        guard let entry = entries[bookID], entry.ownerID == ownerID,
              entry.generation == generation, entry.token == token,
              entry.owner.sourceAccessPermit == permit,
              entry.isPreview == false, entry.isPublished, !entry.invalidated else { return false }
        do {
            let admission = try entry.owner.effectAuthority.admit(permit)
            admission.release()
            return true
        } catch {
            return false
        }
    }

    public func managedSource(for book: Book) async throws -> ManagedBookSource? {
        guard let persistence else { return nil }
        let generation = await currentGeneration()
        guard !synchronousFence.isOwnerTransitioning(book.userId),
              !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
              !synchronousFence.isBookRetired(ownerID: book.userId, generation: generation, bookID: book.id) else { return nil }
        let ownerIDIsCurrent = await currentOwnerID() == book.userId
        guard ownerIDIsCurrent,
              let fingerprint = try await persistence.fingerprint(bookID: book.id, ownerID: book.userId),
              fingerprint.bookID == book.id,
              fingerprint.ownerID == book.userId,
              let url = managedURL(book),
              !book.fileURL.hasPrefix("/"),
              !book.fileURL.split(separator: "/").contains(".."),
              FileManager.default.fileExists(atPath: url.path),
              let observed = try CoordinatedSourceProbe.version(at: url, revision: fingerprint.version.materializationRevision),
              observed == fingerprint.version else { return nil }
        // A ready managed import survives same-owner sign-out/sign-in, but its
        // book and job authorization generations must advance together before
        // the ordinary current-generation read path can admit it.
        guard try await persistence.reauthorizeReadyManagedSource(
            bookID: book.id,
            ownerID: book.userId,
            generation: generation,
            fingerprint: fingerprint
        ) else { return nil }
        if let job = try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) {
            guard job.phase == .ready,
                  job.token.accountGeneration == generation,
                  job.expectedSHA256 == fingerprint.sha256,
                  job.destinationFileIdentifier == fingerprint.version.fileIdentifier,
                  job.promotionRevision == fingerprint.version.materializationRevision else { return nil }
        }
        guard await currentOwnerID() == book.userId, await currentGeneration() == generation,
              !synchronousFence.isOwnerTransitioning(book.userId),
              !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
              !synchronousFence.isBookRetired(ownerID: book.userId, generation: generation, bookID: book.id) else { return nil }
        return ManagedBookSource(bookID: book.id, url: url, fingerprint: fingerprint, accountGeneration: generation)
    }

    public func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
        let generation = await currentGeneration()
        let key = BookKey(ownerID: book.userId, generation: generation, bookID: book.id)
        guard await currentOwnerID() == book.userId,
              !synchronousFence.isOwnerTransitioning(book.userId),
              !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
              !synchronousFence.isBookRetired(ownerID: book.userId, generation: generation, bookID: book.id) else {
            throw BookSourceRegistryError.accountRevoked
        }
        if let failure = currentTerminalFailure(for: key) { throw failure }
        if let managed = try await managedSource(for: book) {
            guard managed.accountGeneration == generation,
                  await currentGeneration() == generation,
                  await currentOwnerID() == book.userId,
                  !synchronousFence.isOwnerTransitioning(book.userId),
                  !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
                  !synchronousFence.isBookRetired(ownerID: book.userId, generation: generation, bookID: book.id) else {
                throw BookSourceRegistryError.accountRevoked
            }
            return managed
        }
        guard await currentGeneration() == generation,
              await currentOwnerID() == book.userId,
              !synchronousFence.isOwnerTransitioning(book.userId),
              !synchronousFence.isFenced(ownerID: book.userId, generation: generation),
              !synchronousFence.isBookRetired(ownerID: book.userId, generation: generation, bookID: book.id) else {
            throw BookSourceRegistryError.accountRevoked
        }
        if let failure = currentTerminalFailure(for: key) { throw failure }
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let failure = currentTerminalFailure(for: key) {
                    continuation.resume(throwing: failure)
                    return
                }
                waiters[waiterID] = ManagedWaiter(book: book, generation: generation, continuation: continuation)
                Task { await self.recheckManagedWaiter(waiterID) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func hasManagedWaiterForTesting(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        waiters.values.contains {
            $0.book.userId == ownerID && $0.generation == generation && $0.book.id == bookID
        }
    }

    private func currentTerminalFailure(for key: BookKey) -> (any Error)? {
        guard let failure = terminalFailures[key] else { return nil }
        let currentAttemptEpoch = synchronousFence.bookAttemptEpoch(
            ownerID: key.ownerID,
            generation: key.generation,
            bookID: key.bookID
        )
        guard failure.attemptEpoch == currentAttemptEpoch else {
            terminalFailures.removeValue(forKey: key)
            return nil
        }
        return failure.error
    }

    public func managedSourceBecameReady(_ source: ManagedBookSource) {
        let key = BookKey(ownerID: source.fingerprint.ownerID, generation: source.accountGeneration, bookID: source.bookID)
        guard !synchronousFence.isOwnerTransitioning(key.ownerID),
              !synchronousFence.isFenced(ownerID: key.ownerID, generation: key.generation),
              !synchronousFence.isBookRetired(ownerID: key.ownerID, generation: key.generation, bookID: key.bookID) else { return }
        terminalFailures.removeValue(forKey: key)
        let matching = waiters.filter { $0.value.book.id == source.bookID && $0.value.book.userId == key.ownerID && $0.value.generation == key.generation }
        for id in matching.keys {
            Task { await self.recheckManagedWaiter(id) }
        }
    }

    public func failPendingSource(for bookID: BookID, error: Error = BookSourceRegistryError.unavailable) {
        let matching = waiters.filter { $0.value.book.id == bookID }
        for (id, waiter) in matching {
            let key = BookKey(ownerID: waiter.book.userId, generation: waiter.generation, bookID: bookID)
            terminalFailures[key] = TerminalFailure(error: error, attemptEpoch: synchronousFence.bookAttemptEpoch(ownerID: key.ownerID, generation: key.generation, bookID: key.bookID))
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: error)
        }
    }

    public func failPendingSource(ownerID: UserID, generation: UInt64, bookID: BookID, error: Error = BookSourceRegistryError.unavailable) {
        let key = BookKey(ownerID: ownerID, generation: generation, bookID: bookID)
        terminalFailures[key] = TerminalFailure(error: error, attemptEpoch: synchronousFence.bookAttemptEpoch(ownerID: ownerID, generation: generation, bookID: bookID))
        let matching = waiters.filter { $0.value.book.id == bookID && $0.value.book.userId == ownerID && $0.value.generation == generation }
        for (id, waiter) in matching {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: error)
        }
    }

    public func retireSource(ownerID: UserID, generation: UInt64, bookID: BookID, error: Error = BookSourceRegistryError.unavailable) {
        synchronousFence.fenceBook(ownerID: ownerID, generation: generation, bookID: bookID)
        if let entry = entries[bookID], entry.ownerID == ownerID, entry.generation == generation { entries.removeValue(forKey: bookID) }
        terminalFailures = terminalFailures.filter { $0.key.ownerID != ownerID || $0.key.generation != generation || $0.key.bookID != bookID }
        failPendingSource(ownerID: ownerID, generation: generation, bookID: bookID, error: error)
    }

    /// Drops only the transient source installed for a registration that has
    /// not yet been published. Unlike retirement, this leaves the BookID open
    /// for a later fresh import attempt.
    func discardTransientSource(ownerID: UserID, generation: UInt64, bookID: BookID, token: BookMaterializationToken) async {
        guard let entry = entries[bookID], entry.ownerID == ownerID,
              entry.generation == generation, entry.token == token,
              entry.isPreview == false else { return }
        entries.removeValue(forKey: bookID)
        entry.owner.invalidation.invalidate()
        entry.owner.effectAuthority.closeAdmission(entry.owner.sourceAccessPermit)
        await entry.owner.effectAuthority.drain(entry.owner.sourceAccessPermit)
    }

    public func drainBook(ownerID: UserID, generation: UInt64, bookID: BookID) async {
        let records = synchronousFence.records(ownerID: ownerID, generation: generation, bookID: bookID)
        await drainRecords(records, waitForOwners: true)
        records.forEach { synchronousFence.unregister($0.permit) }
    }

    public func retire(ownerID: UserID, generation: UInt64) {
        synchronousFence.fence(ownerID: ownerID, generation: generation)
        terminalFailures = terminalFailures.filter { $0.key.ownerID != ownerID || $0.key.generation != generation }
        let removed = entries.filter { $0.value.ownerID == ownerID && $0.value.generation == generation }
        for (bookID, _) in removed {
            entries.removeValue(forKey: bookID)
        }
        let staleWaiters = waiters.filter { $0.value.book.userId == ownerID && $0.value.generation == generation }
        for (id, waiter) in staleWaiters {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: BookSourceRegistryError.accountRevoked)
        }
    }

    /// Nonisolated fence used before the persisted account generation is
    /// advanced. Every registered source authority is closed synchronously.
    public nonisolated func fenceAccountSynchronously(ownerID: UserID, generation: UInt64) -> UInt64 {
        let epoch = synchronousFence.fenceOwnerTransition(ownerID: ownerID)
        synchronousFence.fence(ownerID: ownerID, generation: generation)
        return epoch
    }

    public nonisolated func activateAccountSynchronously(ownerID: UserID, generation: UInt64, epoch: UInt64) -> Bool {
        synchronousFence.unfence(ownerID: ownerID, generation: generation, epoch: epoch)
    }

    public nonisolated func currentTransitionEpoch(ownerID: UserID) -> UInt64 {
        synchronousFence.transitionEpoch(ownerID: ownerID)
    }

    public nonisolated func fenceBookSynchronously(ownerID: UserID, generation: UInt64, bookID: BookID) {
        synchronousFence.fenceBook(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    @discardableResult
    public nonisolated func activateBookSynchronously(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        synchronousFence.activateBook(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    public func drain(ownerID: UserID, generation: UInt64) async {
        await drainRecords(synchronousFence.records(ownerID: ownerID, generation: generation), waitForOwners: true)
    }

    func registerPreview(for book: Book, url: URL) -> BookSourceLease {
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        return BookSourceLease(owner: try! BookSourceOwner(url: url, access: .localPreview, sourceAccessPermit: permit, effectAuthority: authority), cachePolicy: .transient)
    }

    func presenterInvalidated(bookID: BookID, permit: BookSourceAccessPermit, token: BookMaterializationToken?, changedURL: URL?) async {
        guard let entry = entries[bookID], entry.owner.sourceAccessPermit == permit else { return }
        entries.removeValue(forKey: bookID)
        if let token, let persistence {
            for phase in [BookMaterializationPhase.registered, .copying] {
                if (try? await persistence.transition(token: token, from: phase, to: .paused)) == true { break }
            }
        }
        failPendingSource(ownerID: entry.ownerID, generation: entry.generation, bookID: bookID, error: BookSourceRegistryError.unavailable)
        _ = changedURL
    }

    private func recheckManagedWaiter(_ id: UUID) async {
        guard let waiter = waiters[id] else { return }
        do {
            guard let source = try await managedSource(for: waiter.book) else { return }
            guard source.accountGeneration == waiter.generation,
                  !synchronousFence.isOwnerTransitioning(waiter.book.userId),
                  !synchronousFence.isFenced(ownerID: waiter.book.userId, generation: waiter.generation),
                  !synchronousFence.isBookRetired(ownerID: waiter.book.userId, generation: waiter.generation, bookID: waiter.book.id),
                  let current = waiters.removeValue(forKey: id) else { return }
            current.continuation.resume(returning: source)
        } catch {
            guard let current = waiters.removeValue(forKey: id) else { return }
            current.continuation.resume(throwing: error)
        }
    }

    private func drainRecords(_ records: [BookSourceRegistryFence.Record], waitForOwners: Bool) async {
        for record in records { await record.authority.drain(record.permit) }
        if waitForOwners { for record in records { await record.lifetime.waitForRelease() } }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
