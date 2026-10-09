import CryptoKit
import Darwin
import Foundation

public struct BookMaterializationCoordinator: Sendable {
    public enum SampleRepairActivationResult: Sendable {
        case repaired(BookFileFingerprint)
        case alreadyManaged(BookFileFingerprint)
    }

    public enum MaterializationError: Error, Sendable {
        case staleAttempt
        case missingFileProvenance
        case promotedContentMismatch
        case sourceChanged
    }

    private let rootURL: URL
    private let lifecycle: BookImportLifecycle
    private let sourceRegistry: BookSourceRegistry
    private let persistence: any BookImportPersistence
    private let bookStore: any BookStore
    private let currentGeneration: @Sendable () async -> UInt64?
    private let isTombstoned: @Sendable (BookID) async -> Bool
    private let copier: CoordinatedBookCopier
    private let copySelectedSource: @Sendable (
        BookMaterializationToken,
        BookSourceLease,
        URL,
        String,
        Int64,
        ManagedFileVersion
    ) async throws -> StagedBookArtifact
    private let events: BookImportEvents?
    private let onManagedReady: @Sendable (BookMaterializationToken) async -> Void
    private let importInstrumentation: BookImportInstrumentation
    private let reprobeSelectedSource: @Sendable (URL, UUID) async throws -> (sha256: String, byteCount: Int64, version: ManagedFileVersion)
    private let beforeRepairPromotion: @Sendable (URL) throws -> Void
    private let startSelectedSourceScope: @Sendable (URL) -> Bool
    private let stopSelectedSourceScope: @Sendable (URL) -> Void
    private let beforeRetryRegisteredPublication: @Sendable () async -> Void
    private let afterSampleRepairReservation: @Sendable (BookMaterializationToken) async -> Void
    private let beforeSampleRepairCompletionAdmission: @Sendable (BookMaterializationToken) async -> Void
    private let afterSampleRepairPrepared: @Sendable (BookMaterializationToken) async -> Void
    private let afterSampleRepairRename: @Sendable (BookMaterializationToken) async -> Void

    public init(
        rootURL: URL,
        lifecycle: BookImportLifecycle,
        sourceRegistry: BookSourceRegistry,
        persistence: any BookImportPersistence,
        bookStore: any BookStore,
        currentGeneration: @escaping @Sendable () async -> UInt64?,
        isTombstoned: @escaping @Sendable (BookID) async -> Bool = { _ in false },
        copier: CoordinatedBookCopier = CoordinatedBookCopier(),
        copySelectedSource: (@Sendable (
            BookMaterializationToken,
            BookSourceLease,
            URL,
            String,
            Int64,
            ManagedFileVersion
        ) async throws -> StagedBookArtifact)? = nil,
        events: BookImportEvents? = nil,
        onManagedReady: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in },
        reprobeSelectedSource: (@Sendable (URL, UUID) async throws -> (sha256: String, byteCount: Int64, version: ManagedFileVersion))? = nil,
        beforeRepairPromotion: @escaping @Sendable (URL) throws -> Void = { _ in },
        startSelectedSourceScope: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopSelectedSourceScope: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        beforeRetryRegisteredPublication: @escaping @Sendable () async -> Void = {},
        afterSampleRepairReservation: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in },
        beforeSampleRepairCompletionAdmission: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in },
        afterSampleRepairPrepared: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in },
        afterSampleRepairRename: @escaping @Sendable (BookMaterializationToken) async -> Void = { _ in },
        importInstrumentation: BookImportInstrumentation = .shared
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.lifecycle = lifecycle
        self.sourceRegistry = sourceRegistry
        self.persistence = persistence
        self.bookStore = bookStore
        self.currentGeneration = currentGeneration
        self.isTombstoned = isTombstoned
        self.copier = copier
        self.copySelectedSource = copySelectedSource ?? { _, source, stagingURL, expectedSHA256, expectedByteCount, sourceVersion in
            try await copier.copy(
                source: source,
                to: stagingURL,
                expectedSHA256: expectedSHA256,
                expectedByteCount: expectedByteCount,
                sourceVersion: sourceVersion
            )
        }
        self.events = events
        self.onManagedReady = onManagedReady
        self.importInstrumentation = importInstrumentation
        self.beforeRepairPromotion = beforeRepairPromotion
        self.startSelectedSourceScope = startSelectedSourceScope
        self.stopSelectedSourceScope = stopSelectedSourceScope
        self.beforeRetryRegisteredPublication = beforeRetryRegisteredPublication
        self.afterSampleRepairReservation = afterSampleRepairReservation
        self.beforeSampleRepairCompletionAdmission = beforeSampleRepairCompletionAdmission
        self.afterSampleRepairPrepared = afterSampleRepairPrepared
        self.afterSampleRepairRename = afterSampleRepairRename
        self.reprobeSelectedSource = reprobeSelectedSource ?? { url, revision in
            let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: revision)
            return (result.sha256, result.byteCount, result.version)
        }
    }

    public var hasImportEventFeed: Bool { events != nil }

    /// Confirms that a queued registration notification still represents the
    /// current durable attempt before the library publishes it. A successful
    /// admission briefly participates in the same drain accounting as copy
    /// and cover work, so retirement between validation and return is visible
    /// to the caller's post-await generation/deletion checks.
    public func validatesRegistrationEvent(_ event: BookImportEvent) async -> Bool {
        guard case .registered(let eventBook) = event.kind,
              eventBook.id == event.token.bookID,
              eventBook.userId == event.ownerID,
              event.token.ownerID == event.ownerID,
              event.token.accountGeneration == event.accountGeneration,
              await currentGeneration() == event.accountGeneration,
              await isTombstoned(eventBook.id) == false,
              let canonical = try? await bookStore.book(eventBook.id),
              canonical.userId == event.ownerID,
              canonical.fileURL == eventBook.fileURL,
              let pending = try? await persistence.pendingMaterialization(
                bookID: eventBook.id,
                ownerID: event.ownerID
              ),
              pending.token == event.token,
              pending.phase != .cancelled,
              lifecycle.admits(ownerID: event.ownerID, generation: event.accountGeneration),
              let admission = await lifecycle.admitBookMaterialization(event.token) else {
            return false
        }
        defer { admission.release() }
        guard await currentGeneration() == event.accountGeneration,
              await isTombstoned(eventBook.id) == false,
              lifecycle.admits(ownerID: event.ownerID, generation: event.accountGeneration) else { return false }
        return true
    }

    /// Announces a newly persisted canonical registration. Durable imports
    /// can opt into this feed without changing their managed-on-return API.
    public func publishRegistered(
        _ book: Book,
        token: BookMaterializationToken,
        requiringTransientPermit sourcePermit: BookSourceAccessPermit? = nil
    ) async -> Bool {
        guard !Task.isCancelled,
              token.bookID == book.id, token.ownerID == book.userId,
              await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration) else { return false }
        if let sourcePermit {
            guard await sourceRegistry.isPublishedTransientSource(
                ownerID: token.ownerID,
                generation: token.accountGeneration,
                bookID: token.bookID,
                token: token,
                permit: sourcePermit
            ) else { return false }
        }
        guard !Task.isCancelled else { return false }
        let event = BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .registered(book)
        )
        guard await events?.publishIfNotCancelled(event) ?? true else { return false }
        importInstrumentation.record(.bookRegistered, attemptID: token.attemptID)
        return true
    }

    /// Announces a CAS-accepted cover update. Import events never carry URLs
    /// or filesystem paths; observers re-read the canonical Book snapshot.
    public func publishCoverReady(bookID: BookID, token: BookMaterializationToken) async {
        guard token.bookID == bookID,
              await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              let current = try? await persistence.pendingMaterialization(bookID: bookID, ownerID: token.ownerID),
              current.token == token, current.phase == .ready else { return }
        await events?.publish(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .coverReady(bookID)
        ))
    }

    public func publishCoverFailed(bookID: BookID, token: BookMaterializationToken) async {
        guard token.bookID == bookID,
              await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              let current = try? await persistence.pendingMaterialization(bookID: bookID, ownerID: token.ownerID),
              current.token == token, current.phase == .ready else { return }
        await events?.publish(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .coverFailed(bookID)
        ))
    }

    /// Admits background cover extraction only for the current ready attempt.
    /// The returned lifecycle lease must cover extraction, the attempt-owned
    /// file write, and the token-checked coverPath CAS so book/account drains
    /// cannot finish while detached image work can still create files.
    public func admitReadyBookEffect(token: BookMaterializationToken) async -> BookImportMaterializationAdmission? {
        guard let admission = lifecycle.admitBookMaterialization(token) else { return nil }
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              let current = try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              current.token == token, current.phase == .ready,
              let book = try? await bookStore.book(token.bookID),
              book.userId == token.ownerID,
              await isTombstoned(token.bookID) == false else {
            admission.release()
            return nil
        }
        return admission
    }

    /// Safely restores source access after a delete tombstone CAS fails. The
    /// live Book and absence of a tombstone are verified here; the lifecycle
    /// reopens only Book-level admission while keeping the retired attempt
    /// token rejected. A pending copy is parked for an explicit fresh attempt.
    public func restoreBookAfterFailedRetirement(
        book requestedBook: Book,
        token expectedToken: BookMaterializationToken? = nil,
        expectedGeneration: UInt64? = nil
    ) async -> Bool {
        guard let generation = await currentGeneration(),
              expectedGeneration == nil || expectedGeneration == generation,
              lifecycle.admits(ownerID: requestedBook.userId, generation: generation),
              await isTombstoned(requestedBook.id) == false,
              let liveBook = try? await bookStore.book(requestedBook.id),
              liveBook.userId == requestedBook.userId,
              liveBook.fileURL == requestedBook.fileURL else { return false }

        let job: PendingBookMaterialization?
        do {
            job = try await persistence.pendingMaterialization(bookID: requestedBook.id, ownerID: requestedBook.userId)
        } catch {
            return false
        }
        guard expectedToken == nil || expectedToken == job?.token else { return false }
        if let job, job.phase != .ready {
            guard job.token.ownerID == requestedBook.userId,
                  job.token.accountGeneration == generation,
                  await lifecycle.restoreBookAfterFailedRetirement(
                    ownerID: requestedBook.userId,
                    generation: generation,
                    bookID: requestedBook.id,
                    retiredToken: nil
                  ) else { return false }
            // The old attempt remains retired. Recovery must adopt a fresh
            // token before a source can become readable again.
            return false
        }
        guard job == nil || job?.token.accountGeneration == generation else { return false }
        let retiredToken = expectedToken ?? job?.token
        guard await lifecycle.restoreBookAfterFailedRetirement(
            ownerID: requestedBook.userId,
            generation: generation,
            bookID: requestedBook.id,
            retiredToken: retiredToken
        ) else { return false }

        do {
            guard let managed = try await sourceRegistry.managedSource(for: liveBook) else { throw MaterializationError.staleAttempt }
            await sourceRegistry.managedSourceBecameReady(managed)
            _ = try await sourceRegistry.registerSource(
                for: liveBook, url: managed.url, accountGeneration: generation,
                readingPermit: managed.readingPermit,
                token: nil, requiresSecurityScope: false, observeChanges: false
            )
            return true
        } catch {
            lifecycle.retireBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            await lifecycle.drainBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            return false
        }
    }

    /// Local deletion rollback requires proof from that exact deletion. A
    /// parked repair restores Book-level admission but never revives its token.
    public func restoreBookAfterFailedRetirement(
        book requestedBook: Book,
        witness: BookDeletionRetirementWitness?,
        expectedGeneration: UInt64? = nil
    ) async -> Bool {
        guard !Task.isCancelled,
              let witness,
              witness.ownerID == requestedBook.userId, witness.bookID == requestedBook.id,
              let generation = await currentGeneration(), generation == witness.generation,
              expectedGeneration == nil || expectedGeneration == generation,
              lifecycle.admits(ownerID: requestedBook.userId, generation: generation),
              await isTombstoned(requestedBook.id) == false,
              let liveBook = try? await bookStore.book(requestedBook.id), liveBook == requestedBook else { return false }
        let job: PendingBookMaterialization?
        do { job = try await persistence.pendingMaterialization(bookID: requestedBook.id, ownerID: requestedBook.userId) }
        catch { return false }

        if let job, job.phase != .ready {
            guard job.sourceKind == .sampleRepair,
                  job.token.ownerID == requestedBook.userId,
                  job.token.accountGeneration == generation,
                  await persistence.parkSampleRepair(book: liveBook, token: job.token) == .parked,
                  let parked = try? await persistence.pendingMaterialization(bookID: requestedBook.id, ownerID: requestedBook.userId),
                  parked.token == job.token, parked.phase == .paused,
                  await currentGeneration() == generation,
                  await isTombstoned(requestedBook.id) == false,
                  (try? await bookStore.book(requestedBook.id)) == liveBook else { return false }
            return lifecycle.restoreBookFenceAfterFailedRetirement(witness: witness, parkedRepairToken: job.token)
        }

        guard job == nil || job?.token.accountGeneration == generation,
              job == nil || witness.retiredToken == nil || job?.token == witness.retiredToken,
              await currentGeneration() == generation,
              await isTombstoned(requestedBook.id) == false,
              await lifecycle.restoreBookAfterFailedRetirement(witness: witness) else { return false }
        do {
            guard let managed = try await sourceRegistry.managedSource(for: liveBook) else { throw MaterializationError.staleAttempt }
            await sourceRegistry.managedSourceBecameReady(managed)
            _ = try await sourceRegistry.registerSource(
                for: liveBook, url: managed.url, accountGeneration: generation,
                readingPermit: managed.readingPermit, token: nil,
                requiresSecurityScope: false, observeChanges: false
            )
            return true
        } catch {
            lifecycle.retireBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            await lifecycle.drainBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            return false
        }
    }

    /// Restores a Book after the exact local tombstone write failed. Simple
    /// unprepared repairs are parked by exact-token CAS; staged repairs keep
    /// the deletion witness live while targeted recovery runs under a lease.
    public func restoreBookAfterFailedRetirement(
        book requestedBook: Book,
        witness: BookDeletionRetirementWitness?,
        expectedGeneration: UInt64? = nil,
        recoverStartedSampleRepair: @escaping @Sendable (
            Book, BookMaterializationToken, BookImportProvisionalRollbackLease
        ) async -> BookDeletionRollbackResult = { _, _, _ in .refused }
    ) async -> BookDeletionRollbackResult {
        guard let witness,
              witness.ownerID == requestedBook.userId,
              witness.bookID == requestedBook.id,
              let generation = await currentGeneration(),
              generation == witness.generation,
              expectedGeneration == nil || expectedGeneration == generation,
              lifecycle.isCurrentDeletionRetirementWitness(witness),
              await isTombstoned(requestedBook.id) == false,
              let liveBook = try? await bookStore.book(requestedBook.id),
              liveBook == requestedBook,
              await currentGeneration() == generation,
              lifecycle.isCurrentDeletionRetirementWitness(witness) else { return .refused }

        let job: PendingBookMaterialization?
        do {
            job = try await persistence.pendingMaterialization(bookID: requestedBook.id, ownerID: requestedBook.userId)
        } catch {
            return .refused
        }
        guard await currentGeneration() == generation,
              await isTombstoned(requestedBook.id) == false,
              (try? await bookStore.book(requestedBook.id)) == liveBook,
              lifecycle.isCurrentDeletionRetirementWitness(witness) else { return .refused }

        guard let job else {
            return await restoreBookAfterFailedRetirement(
                book: requestedBook, witness: witness, expectedGeneration: generation
            ) ? .existingReady : .refused
        }

        if job.phase == .ready,
           (witness.retiredToken == job.token || witness.retiredToken == nil) {
            return await restoreBookAfterFailedRetirement(
                book: requestedBook, witness: witness, expectedGeneration: generation
            ) ? .existingReady : .refused
        }
        guard job.sourceKind == .sampleRepair,
              job.token.ownerID == requestedBook.userId,
              job.token.accountGeneration == generation,
              job.token.bookID == requestedBook.id else { return .refused }

        if job.phase == .ready {
            return await recoverSampleRepairWithRollbackLease(
                book: liveBook, token: job.token, witness: witness, generation: generation,
                recover: recoverStartedSampleRepair
            )
        }

        let hasPreparedArtifact = job.preparedFileIdentifier != nil
            || job.destinationFileIdentifier != nil
            || job.promotionRevision != nil
        let isUnpreparedCopy = job.phase == .copying && !hasPreparedArtifact
        let canParkUnprepared = !hasPreparedArtifact
            && (job.phase == .registered || isUnpreparedCopy || job.phase == .paused)
        if canParkUnprepared {
            guard await isSafeRetryDestination(job, book: liveBook) else { return .conflict(job.token) }
            guard lifecycle.isCurrentDeletionRetirementWitness(witness),
                  await persistence.parkSampleRepair(book: liveBook, token: job.token) == .parked,
                  await currentGeneration() == generation,
                  await isTombstoned(requestedBook.id) == false,
                  (try? await bookStore.book(requestedBook.id)) == liveBook,
                  lifecycle.isCurrentDeletionRetirementWitness(witness),
                  let parked = try? await persistence.pendingMaterialization(
                    bookID: requestedBook.id, ownerID: requestedBook.userId
                  ), parked.token == job.token, parked.phase == .paused,
                  parked.sourceKind == .sampleRepair,
                  parked.token.ownerID == requestedBook.userId,
                  parked.token.accountGeneration == generation,
                  parked.destinationRelativePath == liveBook.fileURL,
                  parked.expectedSHA256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame,
                  parked.expectedByteCount == job.expectedByteCount else { return .refused }

            if isUnpreparedCopy {
                let stagingURL = rootURL.appendingPathComponent(job.stagingRelativePath).standardizedFileURL
                guard isContained(stagingURL),
                      let latest = try? await persistence.pendingMaterialization(
                        bookID: requestedBook.id, ownerID: requestedBook.userId
                      ), latest.token == job.token, latest.phase == .paused,
                      latest.preparedFileIdentifier == nil,
                      latest.destinationFileIdentifier == nil,
                      latest.promotionRevision == nil else { return .refused }
                try? FileManager.default.removeItem(at: stagingURL)
            }
            guard await currentGeneration() == generation,
                  await isTombstoned(requestedBook.id) == false,
                  (try? await bookStore.book(requestedBook.id)) == liveBook,
                  lifecycle.isCurrentDeletionRetirementWitness(witness) else { return .refused }
            guard await isSafeRetryDestination(parked, book: liveBook) else { return .conflict(job.token) }
            guard !Task.isCancelled,
                  lifecycle.restoreBookFenceAfterFailedRetirement(witness: witness, parkedRepairToken: job.token) else {
                return .refused
            }
            return .retryablePaused(job.token)
        }

        return await recoverSampleRepairWithRollbackLease(
            book: liveBook, token: job.token, witness: witness, generation: generation,
            recover: recoverStartedSampleRepair
        )
    }

    private func recoverSampleRepairWithRollbackLease(
        book: Book,
        token: BookMaterializationToken,
        witness: BookDeletionRetirementWitness,
        generation: UInt64,
        recover: @escaping @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async -> BookDeletionRollbackResult
    ) async -> BookDeletionRollbackResult {
        guard !Task.isCancelled,
              let lease = lifecycle.beginProvisionalDeletionRollback(witness: witness) else { return .refused }
        let result = await recover(book, token, lease)
        guard result.didRestoreBook,
              await currentGeneration() == generation,
              await isTombstoned(book.id) == false,
              (try? await bookStore.book(book.id)) == book,
              lifecycle.isCurrentDeletionRetirementWitness(witness),
              lifecycle.isCurrentProvisionalDeletionRollbackLease(lease) else {
            lifecycle.abortProvisionalDeletionRollback(lease)
            return result == .conflict(token) ? result : .refused
        }
        let terminalToken: BookMaterializationToken
        switch result {
        case let .ready(token), let .retryablePaused(token): terminalToken = token
        case .conflict, .existingReady, .refused:
            lifecycle.abortProvisionalDeletionRollback(lease)
            return result
        }
        guard let finalJob = try? await persistence.pendingMaterialization(
            bookID: book.id, ownerID: book.userId
        ), finalJob.token == terminalToken,
        ((result == .ready(terminalToken) && finalJob.phase == .ready)
            || (result == .retryablePaused(terminalToken) && finalJob.phase == .paused)),
        finalJob.sourceKind == .sampleRepair,
        await currentGeneration() == generation,
        await isTombstoned(book.id) == false,
        (try? await bookStore.book(book.id)) == book,
        !Task.isCancelled,
        lifecycle.isCurrentDeletionRetirementWitness(witness),
        lifecycle.isCurrentProvisionalDeletionRollbackLease(lease),
        lifecycle.finalizeProvisionalDeletionRollback(lease, result: result) else {
            lifecycle.abortProvisionalDeletionRollback(lease)
            return .refused
        }
        return result
    }

    /// A simple retry may proceed only when its destination is absent or the
    /// existing bytes already match the exact sample fingerprint. A competing
    /// destination remains untouched and is surfaced as a conflict.
    private func isSafeRetryDestination(_ job: PendingBookMaterialization, book: Book) async -> Bool {
        let destination = rootURL.appendingPathComponent(job.destinationRelativePath).standardizedFileURL
        guard let generation = await currentGeneration(),
              generation == job.token.accountGeneration,
              await isTombstoned(book.id) == false,
              (try? await bookStore.book(book.id)) == book,
              job.sourceKind == .sampleRepair,
              job.token.bookID == book.id,
              job.token.ownerID == book.userId,
              job.destinationRelativePath == book.fileURL,
              isContained(destination),
              (try? await persistence.readingPermit(
                bookID: book.id, ownerID: book.userId, generation: job.token.accountGeneration
              )) != nil,
              let fingerprint = try? await persistence.sampleRepairFingerprint(
                bookID: book.id, ownerID: book.userId
              ),
              fingerprint.bookID == book.id,
              fingerprint.ownerID == book.userId,
              fingerprint.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame,
              fingerprint.version.byteCount == job.expectedByteCount else { return false }
        var metadata = stat()
        let status = destination.path.withCString { Darwin.lstat($0, &metadata) }
        guard status == 0 else { return errno == ENOENT }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == job.expectedByteCount,
              (try? CoordinatedSourceProbe.version(
                at: destination, revision: fingerprint.version.materializationRevision
              )) == fingerprint.version,
              let observedDigest = try? digest(at: destination) else { return false }
        return observedDigest.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame
    }

    /// Owns sample-repair reservation through promotion admission. A fresh reservation
    /// is activated only while the recovery claim excludes competing lifecycle work.
    public func materializeReservedSampleRepair(
        request: SampleRepairReservationRequest,
        sourceURL: URL
    ) async throws -> SampleRepairActivationResult {
        let book = request.expectedBook
        let token = request.job.token
        guard token.ownerID == book.userId, token.bookID == book.id,
              let claim = lifecycle.claimBookRecovery(
                ownerID: token.ownerID, generation: token.accountGeneration,
                bookID: token.bookID, expectedToken: request.expectedPriorPendingToken
              ) else { throw MaterializationError.staleAttempt }
        defer { claim.release() }

        let currentPrior = try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await isTombstoned(book.id) == false,
              let canonicalBeforeReservation = try? await bookStore.book(book.id), canonicalBeforeReservation == book,
              currentPrior?.token == request.expectedPriorPendingToken,
              (try? await persistence.readingPermit(
                bookID: book.id, ownerID: book.userId, generation: token.accountGeneration
              )) != nil else {
            throw MaterializationError.staleAttempt
        }

        let reservation = try await persistence.reserveSampleRepair(request)
        switch reservation {
        case .alreadyManaged(let fingerprint):
            guard fingerprint == request.expectedFingerprint else { throw MaterializationError.staleAttempt }
            return .alreadyManaged(fingerprint)
        case .reconciled(let fingerprint):
            guard fingerprint == request.expectedFingerprint else { throw MaterializationError.staleAttempt }
            return .alreadyManaged(fingerprint)
        case .reserved(let registration):
            await afterSampleRepairReservation(token)
            guard registration.book == book, registration.token == token,
                  request.job.sourceKind == .sampleRepair, request.job.phase == .registered,
                  request.job.expectedSHA256.caseInsensitiveCompare(request.expectedFingerprint.sha256) == .orderedSame,
                  request.job.expectedByteCount == request.expectedFingerprint.version.byteCount,
                  request.job.destinationRelativePath == book.fileURL else {
                await failReservedSampleRepair(book: book, token: token, claim: claim)
                throw MaterializationError.staleAttempt
            }
            guard claim.allowMaterialization(token) else {
                await failReservedSampleRepair(book: book, token: token, claim: claim)
                throw MaterializationError.staleAttempt
            }
        }

        await claim.drainPriorAttempt()
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await isTombstoned(book.id) == false,
              let canonicalAfterDrain = try? await bookStore.book(book.id), canonicalAfterDrain == book,
              let current = try? await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId),
              current.token == token, current.phase == .registered, current.sourceKind == .sampleRepair,
              current.expectedSHA256.caseInsensitiveCompare(request.expectedFingerprint.sha256) == .orderedSame,
              current.destinationRelativePath == book.fileURL,
              (try? await persistence.readingPermit(
                bookID: book.id, ownerID: book.userId, generation: token.accountGeneration
              )) != nil,
              !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(book.fileURL).path) else {
            await failReservedSampleRepair(book: book, token: token, claim: claim)
            throw MaterializationError.staleAttempt
        }

        guard lifecycle.activatePromotionAttempt(token) else {
            await failReservedSampleRepair(book: book, token: token, claim: claim)
            throw MaterializationError.staleAttempt
        }
        guard let failurePermit = claim.sourceFailurePermit(for: token) else {
            await failReservedSampleRepair(book: book, token: token, claim: claim)
            throw MaterializationError.staleAttempt
        }
        guard let admission = claim.promoteMaterialization(token) else {
            await failReservedSampleRepair(book: book, token: token, claim: claim, failurePermit: failurePermit)
            throw MaterializationError.staleAttempt
        }
        await beforeSampleRepairCompletionAdmission(token)
        guard let completionGuard = lifecycle.admitBookMaterialization(token) else {
            _ = await persistence.parkSampleRepair(book: book, token: token)
            _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
            admission.release()
            throw MaterializationError.staleAttempt
        }
        defer { completionGuard.release() }
        do {
            let fingerprint = try await materialize(
                book: book, token: token, sourceURL: sourceURL, repairOnly: true,
                admission: admission
            )
            return .repaired(fingerprint)
        } catch {
            await sourceRegistry.discardTransientSource(
                ownerID: token.ownerID,
                generation: token.accountGeneration,
                bookID: token.bookID,
                token: token
            )
            await pauseIfCurrentSampleRepair(token, expectedBook: book)
            _ = await lifecycle.failPendingBookSource(book: book, permit: failurePermit)
            await publishFailed(token: token, retryableCode: "materialization_failed")
            throw error
        }
    }

    private func failReservedSampleRepair(
        book: Book, token: BookMaterializationToken, claim: BookImportRecoveryClaim,
        failurePermit: BookImportRecoverySourceFailurePermit? = nil
    ) async {
        _ = await persistence.parkSampleRepair(book: book, token: token)
        if let permit = failurePermit ?? claim.sourceFailurePermit(for: token) {
            _ = await lifecycle.failPendingBookSource(book: book, permit: permit)
        }
    }

    private func pauseIfCurrentSampleRepair(_ token: BookMaterializationToken, expectedBook: Book) async {
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await isTombstoned(token.bookID) == false,
              let canonical = try? await bookStore.book(token.bookID), canonical == expectedBook,
              let pending = try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token, pending.sourceKind == .sampleRepair, pending.phase != .ready else { return }
        _ = try? await persistence.transition(token: token, from: pending.phase, to: .paused)
    }

    /// Completes the durable copy and promotion sequence for a reserved Book.
    /// Readiness is published only after final-path provenance and the
    /// fingerprint commit both win their attempt-token CAS.
    public func materialize(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        publishRegistration: Bool = false,
        reuseRegisteredSource: Bool = false,
        repairOnly: Bool = false,
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        admission suppliedAdmission: BookImportMaterializationAdmission? = nil
    ) async throws -> BookFileFingerprint {
        // Acquire the canonical per-book attempt while the pre-reservation
        // owner gate is still held, then release the broad registration gate
        // before any suspension or copy work.
        let repairFailureIsClaimGuarded = repairOnly && suppliedAdmission != nil
        guard let attempt = lifecycle.admitBookMaterialization(token) else {
            suppliedAdmission?.release()
            throw MaterializationError.staleAttempt
        }
        guard suppliedAdmission == nil || suppliedAdmission?.admits(token) == true else {
            attempt.release()
            suppliedAdmission?.release()
            throw MaterializationError.staleAttempt
        }
        defer { attempt.release() }
        suppliedAdmission?.release()
        guard token.bookID == book.id, token.ownerID == book.userId,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await currentGeneration() == token.accountGeneration,
              let initial = try await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              initial.token == token, initial.phase == .registered,
              (!repairOnly || initial.sourceKind == .sampleRepair) else {
            throw MaterializationError.staleAttempt
        }
        guard try await persistence.transition(token: token, from: .registered, to: .copying) else {
            throw MaterializationError.staleAttempt
        }
        return try await materializeCopying(
            book: book, token: token, sourceURL: sourceURL,
            publishRegistration: publishRegistration,
            reuseRegisteredSource: reuseRegisteredSource,
            repairOnly: repairOnly || initial.sourceKind == .sampleRepair,
            repairFailureIsClaimGuarded: repairFailureIsClaimGuarded,
            onSourceOwnerReleased: onSourceOwnerReleased,
            pending: initial
        )
    }

    /// Installs the selected original as the canonical transient source before
    /// a caller returns the registration to the reader. The later copier can
    /// then join this same source owner instead of replacing it.
    public func registerReadableSource(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        requiresSecurityScope: Bool,
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil
    ) async throws {
        guard token.bookID == book.id, token.ownerID == book.userId,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await currentGeneration() == token.accountGeneration,
              let attempt = lifecycle.admitBookMaterialization(token) else {
            throw MaterializationError.staleAttempt
        }
        defer { attempt.release() }
        guard let pending = try await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token, pending.phase == .registered,
              await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration) else {
            throw MaterializationError.staleAttempt
        }
        let sourcePermit = try await sourceRegistry.registerSource(
            for: book,
            url: sourceURL,
            accountGeneration: token.accountGeneration,
            readingPermit: try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: token.accountGeneration),
            token: token,
            requiresSecurityScope: requiresSecurityScope,
            observeChanges: true,
            published: false,
            onOwnerReleased: onSourceOwnerReleased
        )
        let observed: (sha256: String, byteCount: Int64, version: ManagedFileVersion)
        do {
            observed = try await reprobeSelectedSource(sourceURL, pending.sourceVersion.materializationRevision)
        } catch {
            await rejectUnverifiedReadableSource(token: token)
            throw MaterializationError.sourceChanged
        }
        guard observed.sha256.caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame,
              observed.byteCount == pending.expectedByteCount,
              observed.version == pending.sourceVersion else {
            await rejectUnverifiedReadableSource(token: token)
            throw MaterializationError.sourceChanged
        }
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration) else {
            await rejectUnverifiedReadableSource(token: token)
            throw MaterializationError.staleAttempt
        }
        guard await sourceRegistry.publishTransientSource(
            ownerID: token.ownerID,
            generation: token.accountGeneration,
            bookID: token.bookID,
            token: token,
            permit: sourcePermit
        ) else {
            await rejectUnverifiedReadableSource(token: token)
            throw MaterializationError.sourceChanged
        }
        guard await publishRegistered(book, token: token, requiringTransientPermit: sourcePermit) else {
            await rejectUnverifiedReadableSource(token: token)
            throw MaterializationError.sourceChanged
        }
    }

    private func rejectUnverifiedReadableSource(token: BookMaterializationToken) async {
        await sourceRegistry.discardTransientSource(
            ownerID: token.ownerID,
            generation: token.accountGeneration,
            bookID: token.bookID,
            token: token
        )
        let discarded = (try? await persistence.discardUnpublishedRegistration(token: token)) == true
        if discarded {
            let importsURL = rootURL.appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
            let attemptDirectory = importsURL.appendingPathComponent(token.attemptID.uuidString, isDirectory: true).standardizedFileURL
            if attemptDirectory.deletingLastPathComponent() == importsURL {
                try? FileManager.default.removeItem(at: attemptDirectory)
            }
        } else {
            await pause(token)
        }
        await sourceRegistry.failPendingSource(
            ownerID: token.ownerID,
            generation: token.accountGeneration,
            bookID: token.bookID,
            error: BookSourceRegistryError.unavailable
        )
    }

    /// Waits for another import attempt that reserved the same content to
    /// finish. The registry revalidates the persisted ready provenance before
    /// returning, so this never treats a notification as proof of readiness.
    public func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
        try await sourceRegistry.awaitManagedSource(for: book)
    }

    /// Validates that the current registry can still vend a readable lease for
    /// this canonical book immediately before an early-open callback.
    public func isBookRetiredForDeletion(ownerID: UserID, generation: UInt64, bookID: BookID) -> Bool {
        lifecycle.isBookRetiredForDeletion(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    public func isReadableSourceAvailable(for book: Book) async -> Bool {
        guard let lease = try? await sourceRegistry.acquireReadableSource(for: book) else { return false }
        return lease.url.isFileURL && FileManager.default.fileExists(atPath: lease.url.path)
    }

    /// Closes the recovery race before a new `.registered` row is persisted.
    /// Pass the returned lease to `materialize` or `retryAndMaterialize`.
    public func admitRegistration(ownerID: UserID, generation: UInt64, bookID: BookID) -> BookImportMaterializationAdmission? {
        lifecycle.admitBookRegistration(ownerID: ownerID, generation: generation, bookID: bookID)
    }

    /// Waits only when recovery currently owns this exact book. Fences and
    /// unrelated admission failures remain failures instead of spinning.
    public func admitRegistrationAfterRecovery(
        ownerID: UserID,
        generation: UInt64,
        bookID: BookID
    ) async -> BookImportMaterializationAdmission? {
        while true {
            guard !Task.isCancelled else { return nil }
            if let admission = lifecycle.admitBookRegistration(ownerID: ownerID, generation: generation, bookID: bookID) {
                guard !Task.isCancelled else {
                    admission.release()
                    return nil
                }
                return admission
            }
            let waitedForRecovery = await lifecycle.waitForBookRecoveryClaimIfPresent(
                ownerID: ownerID,
                generation: generation,
                bookID: bookID
            )
            guard !Task.isCancelled else { return nil }
            guard waitedForRecovery else {
                guard let admission = lifecycle.admitBookRegistration(ownerID: ownerID, generation: generation, bookID: bookID) else {
                    return nil
                }
                guard !Task.isCancelled else {
                    admission.release()
                    return nil
                }
                return admission
            }
        }
    }

    /// Persists account admission before `AppDependencies` opens lifecycle
    /// admission for a newly authenticated owner.
    public func authorizeAccount(ownerID: UserID, generation: UInt64) async throws {
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
    }

    /// Rotates a terminal attempt only after its old source/promotion work has
    /// drained, retaining the canonical BookID and all Book metadata.
    public func retryAndMaterialize(
        book: Book,
        newSource: PendingBookMaterialization,
        retiredAttempt: RetiredBookMaterializationAttempt,
        sourceURL: URL,
        publishRegistration: Bool = false,
        requiresSecurityScope: Bool = false,
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        onRegistrationAccepted: (@Sendable () -> Void)? = nil,
        admission suppliedAdmission: BookImportMaterializationAdmission? = nil
    ) async throws -> BookRegistration {
        let registrationAdmission = suppliedAdmission ?? lifecycle.admitBookRegistration(
            ownerID: newSource.token.ownerID,
            generation: newSource.token.accountGeneration,
            bookID: newSource.token.bookID
        )
        guard let registrationAdmission, registrationAdmission.admits(newSource.token) else {
            registrationAdmission?.release()
            throw MaterializationError.staleAttempt
        }
        defer { registrationAdmission.release() }
        let oldToken = retiredAttempt.token
        guard oldToken.bookID == book.id, oldToken.ownerID == book.userId,
              newSource.token.bookID == book.id,
              newSource.token.ownerID == book.userId,
              lifecycle.admits(ownerID: newSource.token.ownerID, generation: newSource.token.accountGeneration),
              await currentGeneration() == newSource.token.accountGeneration else {
            throw MaterializationError.staleAttempt
        }
        let permit = AccountMutationPermit(ownerID: book.userId, accountGeneration: newSource.token.accountGeneration)
        guard let expectation = try await persistence.retryExpectation(bookID: book.id, ownerID: book.userId, accountPermit: permit),
              expectation.pending.token == oldToken else { throw MaterializationError.staleAttempt }
        registrationAdmission.release()
        let readable = try await retryAndRegisterReadableSource(
            book: book, accountPermit: permit, retryExpectation: expectation,
            newSource: newSource, retiredAttempt: retiredAttempt, sourceURL: sourceURL,
            requiresSecurityScope: requiresSecurityScope, onSourceOwnerReleased: onSourceOwnerReleased,
            onRegistrationAccepted: onRegistrationAccepted
        )
        defer { readable.admission.release() }
        let token = readable.registration.token!
        _ = try await materialize(book: readable.registration.book, token: token, sourceURL: sourceURL,
                                  reuseRegisteredSource: true, onSourceOwnerReleased: onSourceOwnerReleased,
                                  admission: readable.admission)
        return readable.registration
    }

    /// Replaces a terminal/paused persisted attempt and publishes the selected
    /// source only after the exact old token has drained and the strict CAS wins.
    public func retryAndRegisterReadableSource(
        book: Book,
        accountPermit: AccountMutationPermit,
        retryExpectation: BookImportRetryExpectation,
        newSource: PendingBookMaterialization,
        retiredAttempt: RetiredBookMaterializationAttempt,
        sourceURL: URL,
        requiresSecurityScope: Bool,
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        onRegistrationAccepted: (@Sendable () -> Void)? = nil
    ) async throws -> (registration: BookRegistration, admission: BookImportMaterializationAdmission) {
        let oldToken = retiredAttempt.token
        guard accountPermit.ownerID == book.userId,
              accountPermit.accountGeneration == newSource.token.accountGeneration,
              retryExpectation.book == book, retryExpectation.pending.token == oldToken,
              oldToken.ownerID == book.userId, oldToken.bookID == book.id,
              newSource.token.ownerID == book.userId, newSource.token.bookID == book.id,
              newSource.token != oldToken,
              lifecycle.admits(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration),
              await currentGeneration() == accountPermit.accountGeneration else {
            throw MaterializationError.staleAttempt
        }

        guard let claim = lifecycle.claimAttemptRetry(accountPermit: accountPermit, retiring: oldToken) else {
            throw MaterializationError.staleAttempt
        }
        defer { claim.release() }
        let drained = await claim.drain()
        try Task.checkCancellation()
        guard drained.token == oldToken,
              lifecycle.admits(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration),
              await currentGeneration() == accountPermit.accountGeneration,
              await isTombstoned(book.id) == false,
              let currentExpectation = try await persistence.retryExpectation(bookID: book.id, ownerID: book.userId, accountPermit: accountPermit),
              currentExpectation == retryExpectation else { throw MaterializationError.staleAttempt }

        let didStartSelectedScope = requiresSecurityScope && startSelectedSourceScope(sourceURL)
        guard !requiresSecurityScope || didStartSelectedScope else { throw BookSourceOwnerError.securityScopeUnavailable }
        defer { if didStartSelectedScope { stopSelectedSourceScope(sourceURL) } }
        let selected: (sha256: String, byteCount: Int64, version: ManagedFileVersion)
        do {
            selected = try await reprobeSelectedSource(sourceURL, newSource.sourceVersion.materializationRevision)
        } catch { throw MaterializationError.sourceChanged }
        try Task.checkCancellation()
        guard selected.sha256.caseInsensitiveCompare(newSource.expectedSHA256) == .orderedSame,
              selected.sha256.caseInsensitiveCompare(retryExpectation.pending.expectedSHA256) == .orderedSame,
              selected.byteCount == newSource.expectedByteCount,
              selected.byteCount == retryExpectation.pending.expectedByteCount,
              selected.version == newSource.sourceVersion,
              lifecycle.admits(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration),
              await currentGeneration() == accountPermit.accountGeneration,
              await isTombstoned(book.id) == false else { throw MaterializationError.sourceChanged }

        try Task.checkCancellation()
        guard let registration = try await persistence.retryPendingMaterialization(
            expected: retryExpectation, accountPermit: accountPermit, newSource: newSource,
            verifiedSourceSHA256: selected.sha256, verifiedSourceByteCount: selected.byteCount,
            verifiedSourceVersion: selected.version, retiredAttempt: drained
        ), registration.disposition == .retried, registration.token == newSource.token else {
            throw MaterializationError.staleAttempt
        }
        onRegistrationAccepted?()
        if Task.isCancelled {
            await pause(newSource.token)
            await sourceRegistry.failPendingSource(ownerID: book.userId, generation: accountPermit.accountGeneration,
                                                   bookID: book.id, error: CancellationError())
            throw CancellationError()
        }
        guard lifecycle.admits(ownerID: accountPermit.ownerID, generation: accountPermit.accountGeneration),
              await currentGeneration() == accountPermit.accountGeneration,
              await isTombstoned(book.id) == false,
              let admission = claim.activate(newSource.token) else {
            await pause(newSource.token)
            await sourceRegistry.failPendingSource(ownerID: book.userId, generation: accountPermit.accountGeneration,
                                                   bookID: book.id, error: BookSourceRegistryError.unavailable)
            throw MaterializationError.staleAttempt
        }
        do {
            try await registerRetryReadableSource(book: registration.book, token: newSource.token,
                                                  sourceURL: sourceURL, requiresSecurityScope: requiresSecurityScope,
                                                  onSourceOwnerReleased: onSourceOwnerReleased)
        } catch {
            admission.release()
            throw error
        }
        if Task.isCancelled {
            await discardRetryReadableSource(token: newSource.token, error: CancellationError())
            admission.release()
            throw CancellationError()
        }
        return (registration, admission)
    }

    private func registerRetryReadableSource(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        requiresSecurityScope: Bool,
        onSourceOwnerReleased: (@Sendable () -> Void)?
    ) async throws {
        let pending: PendingBookMaterialization
        do {
            guard await currentGeneration() == token.accountGeneration,
                  lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
                  let current = try await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
                  current.token == token, current.phase == .registered,
                  await isTombstoned(book.id) == false else { throw MaterializationError.staleAttempt }
            pending = current
            try Task.checkCancellation()
            guard let permit = try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: token.accountGeneration) else {
                throw MaterializationError.staleAttempt
            }
            let sourcePermit = try await sourceRegistry.registerSource(
                for: book, url: sourceURL, accountGeneration: token.accountGeneration,
                readingPermit: permit, token: token, requiresSecurityScope: requiresSecurityScope,
                observeChanges: true, published: false, onOwnerReleased: onSourceOwnerReleased
            )
            do {
                let observed: (sha256: String, byteCount: Int64, version: ManagedFileVersion)
                do {
                    observed = try await reprobeSelectedSource(sourceURL, pending.sourceVersion.materializationRevision)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw MaterializationError.sourceChanged
                }
                try Task.checkCancellation()
                guard observed.sha256.caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame,
                      observed.byteCount == pending.expectedByteCount,
                      observed.version == pending.sourceVersion,
                      lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
                      await currentGeneration() == token.accountGeneration,
                      await isTombstoned(book.id) == false else { throw MaterializationError.sourceChanged }
                try Task.checkCancellation()
                guard await sourceRegistry.publishTransientSource(ownerID: token.ownerID, generation: token.accountGeneration,
                                                                  bookID: token.bookID, token: token, permit: sourcePermit) else {
                    throw MaterializationError.sourceChanged
                }
                try Task.checkCancellation()
                await beforeRetryRegisteredPublication()
                try Task.checkCancellation()
                guard await publishRegistered(book, token: token, requiringTransientPermit: sourcePermit) else {
                    throw MaterializationError.sourceChanged
                }
                try Task.checkCancellation()
            } catch {
                await discardRetryReadableSource(token: token, error: error)
                throw error
            }
        } catch {
            if (try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID))?.token == token {
                await discardRetryReadableSource(token: token, error: error)
            }
            throw error
        }
    }

    private func discardRetryReadableSource(token: BookMaterializationToken, error: Error) async {
        await sourceRegistry.discardTransientSource(ownerID: token.ownerID, generation: token.accountGeneration,
                                                    bookID: token.bookID, token: token)
        await pause(token)
        await sourceRegistry.failPendingSource(ownerID: token.ownerID, generation: token.accountGeneration,
                                               bookID: token.bookID, error: error)
    }

    /// Resumes an attempt that `BookImportRecovery` adopted after validating
    /// its persisted inode and digest provenance.
    public func resumeRecovered(
        book: Book,
        token: BookMaterializationToken,
        provisionalRollbackLease: BookImportProvisionalRollbackLease? = nil
    ) async throws -> BookFileFingerprint {
        guard let attempt = lifecycle.admitBookMaterialization(token, provisionalRollbackLease: provisionalRollbackLease) else {
            throw MaterializationError.staleAttempt
        }
        defer { attempt.release() }
        guard token.bookID == book.id, token.ownerID == book.userId,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await currentGeneration() == token.accountGeneration,
              let pending = try await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token else { throw MaterializationError.staleAttempt }

        switch pending.phase {
        case .registered, .copying:
            guard pending.sourceKind != .sampleRepair else { throw MaterializationError.staleAttempt }
            let sourceURL = try await resolveSourceURL(for: pending, token: token)
            if pending.phase != .copying {
                guard try await persistence.transition(token: token, from: pending.phase, to: .copying) else {
                    throw MaterializationError.staleAttempt
                }
            }
            return try await materializeCopying(
                book: book, token: token, sourceURL: sourceURL,
                requiresSecurityScope: pending.sourceKind == .securityScopedOriginal,
                pending: pending
            )
        case .paused:
            if pending.preparedFileIdentifier != nil {
                let resumedPhase: BookMaterializationPhase = pending.promotionRevision == nil ? .prepared : .promoting
                guard try await persistence.transition(token: token, from: .paused, to: resumedPhase) else {
                    throw MaterializationError.staleAttempt
                }
                let resumed = Self.copy(pending, phase: resumedPhase)
                return try await resumeStagedPromotion(book: book, token: token, pending: resumed)
            }
            guard pending.sourceKind != .sampleRepair else { throw MaterializationError.staleAttempt }
            let sourceURL = try await resolveSourceURL(for: pending, token: token)
            guard try await persistence.transition(token: token, from: .paused, to: .copying) else {
                throw MaterializationError.staleAttempt
            }
            return try await materializeCopying(
                book: book, token: token, sourceURL: sourceURL,
                requiresSecurityScope: pending.sourceKind == .securityScopedOriginal,
                pending: pending
            )
        case .prepared, .promoting:
            return try await resumeStagedPromotion(book: book, token: token, pending: pending)
        case .promoted:
            let fingerprint = try await lifecycle.withPromotionPermit(token: token) {
                try await self.commitVerifiedDestination(book: book, token: token, pending: pending)
            }
            await publishManagedReady(book: book, generation: token.accountGeneration, fingerprint: fingerprint)
            return fingerprint
        case .ready:
            guard let fingerprint = try await persistence.fingerprint(bookID: book.id, ownerID: book.userId) else {
                throw MaterializationError.missingFileProvenance
            }
            return fingerprint
        case .failed, .cancelled:
            throw MaterializationError.staleAttempt
        }
    }

    /// Stops admitting account work, waits until provider-coordinated copy and
    /// promotion effects return, persists retryable phases, then reopens only
    /// if no newer account transition superseded this pause operation.
    @discardableResult
    public func fenceAccountForPause(ownerID: UserID, generation: UInt64) -> BookImportActivationToken {
        lifecycle.fenceAccount(ownerID: ownerID, generation: generation)
    }

    public func pauseAccount(ownerID: UserID, generation: UInt64, activationToken: BookImportActivationToken? = nil) async {
        let activation = activationToken ?? lifecycle.fenceAccount(ownerID: ownerID, generation: generation)
        await lifecycle.drainAccount(ownerID, generation: generation)
        if let books = try? await bookStore.books(for: ownerID) {
            for book in books where book.userId == ownerID {
                guard let job = try? await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID),
                      job.token.accountGeneration == generation,
                      job.phase != .ready, job.phase != .failed, job.phase != .cancelled else { continue }
                _ = try? await persistence.transition(token: job.token, from: job.phase, to: .paused)
            }
        }
        _ = lifecycle.activateAccount(activation)
    }

    private func materializeCopying(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        publishRegistration: Bool = false,
        reuseRegisteredSource: Bool = false,
        repairOnly: Bool = false,
        repairFailureIsClaimGuarded: Bool = false,
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        requiresSecurityScope: Bool = false,
        pending initial: PendingBookMaterialization
    ) async throws -> BookFileFingerprint {
        guard let operation = lifecycle.admitOwnerOperation(ownerID: token.ownerID, generation: token.accountGeneration) else {
            throw MaterializationError.staleAttempt
        }
        defer { operation.release() }
        let stagingURL = rootURL.appendingPathComponent(initial.stagingRelativePath).standardizedFileURL
        var recordedPreparedArtifact = false
        do {
            guard isContained(stagingURL) else { throw MaterializationError.staleAttempt }
            if !reuseRegisteredSource {
                _ = try await sourceRegistry.registerSource(
                    for: book,
                    url: sourceURL,
                    accountGeneration: token.accountGeneration,
                    readingPermit: try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: token.accountGeneration),
                    token: token,
                    requiresSecurityScope: requiresSecurityScope,
                    observeChanges: false,
                    onOwnerReleased: onSourceOwnerReleased
                )
                if publishRegistration {
                    _ = await publishRegistered(book, token: token)
                }
            }
            let source = try await sourceRegistry.acquireReadableSource(for: book)
            if reuseRegisteredSource,
               (source.url.standardizedFileURL != sourceURL.standardizedFileURL || source.cachePolicy != .transient) {
                throw MaterializationError.staleAttempt
            }
            let staged = try await copySelectedSource(
                token,
                source,
                stagingURL,
                initial.expectedSHA256,
                initial.expectedByteCount,
                initial.sourceVersion
            )
            guard let preparedID = staged.version.fileIdentifier, !preparedID.isEmpty else {
                throw MaterializationError.missingFileProvenance
            }
            let artifacts = VerifiedBookArtifacts(
                sha256: staged.sha256,
                byteCount: staged.byteCount,
                stagingRelativePath: initial.stagingRelativePath,
                destinationRelativePath: initial.destinationRelativePath,
                preparedFileIdentifier: preparedID,
                destinationFileIdentifier: nil,
                promotionRevision: nil
            )
            guard try await persistence.recordPrepared(token: token, artifacts: artifacts) else {
                throw MaterializationError.staleAttempt
            }
            recordedPreparedArtifact = true
            if repairOnly {
                await afterSampleRepairPrepared(token)
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            let fingerprint = try await lifecycle.withPromotionPermit(token: token) {
                try await self.promote(book: book, token: token, sourceURL: source.url, sourceVersion: initial.sourceVersion, artifact: staged, repairOnly: repairOnly)
            }
            await publishManagedReady(book: book, generation: token.accountGeneration, fingerprint: fingerprint)
            return fingerprint
        } catch {
            if !repairFailureIsClaimGuarded {
                await pause(token)
                await sourceRegistry.failPendingSource(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID, error: error)
                await publishFailed(token: token, retryableCode: "materialization_failed")
            }
            if isContained(stagingURL) {
                if !repairOnly {
                    try? FileManager.default.removeItem(at: stagingURL)
                } else if !recordedPreparedArtifact,
                          let current = try? await persistence.pendingMaterialization(
                            bookID: token.bookID, ownerID: token.ownerID
                          ), current.token == token, current.sourceKind == .sampleRepair,
                          current.phase == .copying,
                          current.preparedFileIdentifier == nil,
                          current.destinationFileIdentifier == nil,
                          current.promotionRevision == nil {
                    // The copy has unwound, and this exact attempt still owns
                    // an unverified partial. Never remove a prepared artifact.
                    try? FileManager.default.removeItem(at: stagingURL)
                }
            }
            throw error
        }
    }

    private func resumeStagedPromotion(
        book: Book,
        token: BookMaterializationToken,
        pending: PendingBookMaterialization
    ) async throws -> BookFileFingerprint {
        let stagingURL = rootURL.appendingPathComponent(pending.stagingRelativePath).standardizedFileURL
        let destinationURL = rootURL.appendingPathComponent(pending.destinationRelativePath).standardizedFileURL
        guard isContained(stagingURL), isContained(destinationURL),
              let preparedID = pending.preparedFileIdentifier,
              !preparedID.isEmpty else { throw MaterializationError.missingFileProvenance }

        let fingerprint = try await lifecycle.withPromotionPermit(token: token) {
            guard await self.currentGeneration() == token.accountGeneration,
                  self.lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
                  await self.isTombstoned(book.id) == false,
                  let currentBook = try await self.bookStore.book(book.id),
                  currentBook.userId == token.ownerID,
                  currentBook.fileURL == pending.destinationRelativePath else { throw MaterializationError.staleAttempt }

            var promotionRevision = pending.promotionRevision
            if pending.phase == .prepared {
                let stageVersion = try CoordinatedSourceProbe.version(at: stagingURL, revision: pending.sourceVersion.materializationRevision)
                guard stageVersion?.fileIdentifier == preparedID,
                      stageVersion?.byteCount == pending.expectedByteCount,
                      try self.digest(at: stagingURL).caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame else {
                    throw MaterializationError.missingFileProvenance
                }
                let revision = UUID()
                try Task.checkCancellation()
                guard try await self.persistence.claimPromotion(token: token, preparedFileIdentifier: preparedID, promotionRevision: revision) else {
                    throw MaterializationError.staleAttempt
                }
                try Task.checkCancellation()
                promotionRevision = revision
            }
            guard let promotionRevision else { throw MaterializationError.missingFileProvenance }

            let destinationMatches = try self.verifiedDestination(destinationURL, expectedID: preparedID, revision: promotionRevision, pending: pending)
            if !destinationMatches {
                let stageVersion = try CoordinatedSourceProbe.version(at: stagingURL, revision: pending.sourceVersion.materializationRevision)
                guard stageVersion?.fileIdentifier == preparedID,
                      stageVersion?.byteCount == pending.expectedByteCount,
                      try self.digest(at: stagingURL).caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame else {
                    throw MaterializationError.missingFileProvenance
                }
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let status: Int32
                if pending.sourceKind == .sampleRepair {
                    try self.beforeRepairPromotion(destinationURL)
                    try Task.checkCancellation()
                    status = stagingURL.path.withCString { sourcePath in
                        destinationURL.path.withCString { destinationPath in Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) }
                    }
                } else {
                    status = stagingURL.path.withCString { sourcePath in
                        destinationURL.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
                    }
                }
                guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if pending.sourceKind == .sampleRepair {
                    await self.afterSampleRepairRename(token)
                    try Task.checkCancellation()
                }
            }

            try Task.checkCancellation()
            guard try self.verifiedDestination(destinationURL, expectedID: preparedID, revision: promotionRevision, pending: pending),
                  try await self.persistence.recordPromoted(token: token, preparedFileIdentifier: preparedID, destinationFileIdentifier: preparedID, promotionRevision: promotionRevision) else {
                // A prior crash may already have committed this CAS. Re-read
                // before failing so adoption remains idempotent.
                let refreshed = try await self.persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID)
                guard refreshed?.token == token, refreshed?.phase == .promoted else { throw MaterializationError.staleAttempt }
                return try await self.commitVerifiedDestination(book: book, token: token, pending: refreshed!)
            }
            return try await self.commitVerifiedDestination(
                book: book,
                token: token,
                pending: PendingBookMaterialization(
                    token: token, sourceKind: pending.sourceKind, sourceBookmark: pending.sourceBookmark,
                    ownedSourceRelativePath: pending.ownedSourceRelativePath, sourceVersion: pending.sourceVersion,
                    expectedSHA256: pending.expectedSHA256, expectedByteCount: pending.expectedByteCount,
                    stagingRelativePath: pending.stagingRelativePath, destinationRelativePath: pending.destinationRelativePath,
                    phase: .promoted, preparedFileIdentifier: preparedID,
                    destinationFileIdentifier: preparedID, promotionRevision: promotionRevision
                )
            )
        }
        await publishManagedReady(book: book, generation: token.accountGeneration, fingerprint: fingerprint)
        return fingerprint
    }

    private func commitVerifiedDestination(book: Book, token: BookMaterializationToken, pending: PendingBookMaterialization) async throws -> BookFileFingerprint {
        try Task.checkCancellation()
        let destinationURL = rootURL.appendingPathComponent(pending.destinationRelativePath).standardizedFileURL
        guard isContained(destinationURL), let expectedID = pending.destinationFileIdentifier,
              let revision = pending.promotionRevision,
              try verifiedDestination(destinationURL, expectedID: expectedID, revision: revision, pending: pending),
              let finalVersion = try CoordinatedSourceProbe.version(at: destinationURL, revision: revision) else {
            throw MaterializationError.missingFileProvenance
        }
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: pending.expectedSHA256, version: finalVersion)
        try Task.checkCancellation()
        guard try await persistence.commitManaged(token: token, fingerprint: fingerprint) else {
            if let existing = try await persistence.fingerprint(bookID: book.id, ownerID: book.userId),
               existing == fingerprint { return existing }
            throw MaterializationError.staleAttempt
        }
        return fingerprint
    }

    private func publishManagedReady(book: Book, generation: UInt64, fingerprint: BookFileFingerprint) async {
        guard let managed = try? await sourceRegistry.managedSource(for: book) else { return }
        await sourceRegistry.managedSourceBecameReady(managed)
        _ = try? await sourceRegistry.registerSource(
            for: book, url: managed.url, accountGeneration: generation,
            readingPermit: managed.readingPermit,
            token: nil, requiresSecurityScope: false, observeChanges: false
        )
        guard await currentGeneration() == generation,
              lifecycle.admits(ownerID: book.userId, generation: generation),
              let pending = try? await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId),
              pending.phase == .ready,
              pending.token.ownerID == book.userId,
              pending.token.accountGeneration == generation,
              pending.expectedSHA256.caseInsensitiveCompare(fingerprint.sha256) == .orderedSame else { return }
        importInstrumentation.record(.managedSourceReady, attemptID: pending.token.attemptID)
        await events?.publish(BookImportEvent(
            ownerID: book.userId, accountGeneration: generation,
            token: pending.token, kind: .managedReady(book.id)
        ))
        await onManagedReady(pending.token)
    }

    func publishReconciledManagedReady(book: Book, generation: UInt64, fingerprint: BookFileFingerprint) async -> Bool {
        await publishManagedReady(book: book, generation: generation, fingerprint: fingerprint)
        guard await currentGeneration() == generation,
              lifecycle.admits(ownerID: book.userId, generation: generation),
              let managed = try? await sourceRegistry.managedSource(for: book),
              managed.fingerprint == fingerprint else { return false }
        do {
            let lease = try await sourceRegistry.acquireReadableSource(for: book)
            return lease.url.standardizedFileURL == managed.url.standardizedFileURL
        } catch {
            return false
        }
    }

    private func publishFailed(token: BookMaterializationToken, retryableCode: String) async {
        guard await currentGeneration() == token.accountGeneration,
              lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration) else { return }
        await events?.publish(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .failed(token.bookID, retryableCode: retryableCode)
        ))
    }

    private func verifiedDestination(_ url: URL, expectedID: String, revision: UUID, pending: PendingBookMaterialization) throws -> Bool {
        var metadata = stat()
        let status = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard status == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let version = try CoordinatedSourceProbe.version(at: url, revision: revision) else { return false }
        guard version.fileIdentifier == expectedID, version.byteCount == pending.expectedByteCount else { return false }
        let actualDigest = try digest(at: url)
        return actualDigest.caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame
    }

    private func isContained(_ url: URL) -> Bool {
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return url.path.hasPrefix(prefix) && url.path != rootURL.path
    }

    private func resolveSourceURL(for job: PendingBookMaterialization, token: BookMaterializationToken) async throws -> URL {
        switch job.sourceKind {
        case .securityScopedOriginal:
            guard let bookmark = job.sourceBookmark else { throw MaterializationError.staleAttempt }
            let resolved = try await BookSourceBookmarkCodec().resolveRefreshing(bookmark) {
                guard self.lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
                      await self.currentGeneration() == token.accountGeneration,
                      let current = try? await self.persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID) else { return false }
                return current.token == token
            }
            if let refreshedData = resolved.refreshedData {
                guard try await persistence.refreshSourceBookmark(token: token, refreshedData: refreshedData) else {
                    throw MaterializationError.staleAttempt
                }
            }
            return resolved.url
        case .ownedStaging:
            guard let relativePath = job.ownedSourceRelativePath, !relativePath.isEmpty else {
                throw MaterializationError.staleAttempt
            }
            let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
            guard isContained(url) else { throw MaterializationError.staleAttempt }
            return url
        case .sampleRepair:
            throw MaterializationError.staleAttempt
        }
    }

    private static func copy(_ job: PendingBookMaterialization, phase: BookMaterializationPhase) -> PendingBookMaterialization {
        PendingBookMaterialization(
            token: job.token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath,
            phase: phase, retryableErrorCode: job.retryableErrorCode,
            preparedFileIdentifier: job.preparedFileIdentifier,
            destinationFileIdentifier: job.destinationFileIdentifier,
            promotionRevision: job.promotionRevision
        )
    }

    private func promote(
        book: Book,
        token: BookMaterializationToken,
        sourceURL: URL,
        sourceVersion: ManagedFileVersion,
        artifact: StagedBookArtifact,
        repairOnly: Bool
    ) async throws -> BookFileFingerprint {
        guard lifecycle.admits(ownerID: token.ownerID, generation: token.accountGeneration),
              await currentGeneration() == token.accountGeneration,
              await isTombstoned(book.id) == false,
              let pending = try await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token,
              pending.phase == .prepared,
              let currentBook = try await bookStore.book(book.id),
              currentBook.userId == token.ownerID,
              currentBook.fileURL == pending.destinationRelativePath,
              try CoordinatedSourceProbe.version(at: artifact.url, revision: sourceVersion.materializationRevision) == artifact.version,
              artifact.version.byteCount == pending.expectedByteCount,
              artifact.sha256.caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame,
              try digest(at: artifact.url).caseInsensitiveCompare(pending.expectedSHA256) == .orderedSame,
              try CoordinatedSourceProbe.version(at: sourceURL, revision: sourceVersion.materializationRevision) == sourceVersion else {
            throw MaterializationError.staleAttempt
        }
        guard let preparedFileIdentifier = artifact.version.fileIdentifier else {
            throw MaterializationError.missingFileProvenance
        }
        let promotionRevision = UUID()
        try Task.checkCancellation()
        guard try await persistence.claimPromotion(token: token, preparedFileIdentifier: preparedFileIdentifier, promotionRevision: promotionRevision) else {
            throw MaterializationError.staleAttempt
        }
        try Task.checkCancellation()

        let destinationURL = rootURL.appendingPathComponent(pending.destinationRelativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destinationURL.path.hasPrefix(rootPath), destinationURL.path != rootURL.path else {
            throw MaterializationError.staleAttempt
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if repairOnly {
            try beforeRepairPromotion(destinationURL)
            try Task.checkCancellation()
        }
        let status: Int32
        if repairOnly {
            status = artifact.url.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) }
            }
        } else {
            status = artifact.url.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if repairOnly {
            await afterSampleRepairRename(token)
            try Task.checkCancellation()
        }

        guard let finalVersion = try CoordinatedSourceProbe.version(at: destinationURL, revision: promotionRevision),
              finalVersion.fileIdentifier == preparedFileIdentifier,
              finalVersion.byteCount == pending.expectedByteCount,
              try digest(at: destinationURL) == pending.expectedSHA256.lowercased() else {
            throw MaterializationError.promotedContentMismatch
        }
        try Task.checkCancellation()
        guard try await persistence.recordPromoted(
            token: token,
            preparedFileIdentifier: preparedFileIdentifier,
            destinationFileIdentifier: preparedFileIdentifier,
            promotionRevision: promotionRevision
        ) else {
            throw MaterializationError.staleAttempt
        }
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: pending.expectedSHA256, version: finalVersion)
        try Task.checkCancellation()
        guard try await persistence.commitManaged(token: token, fingerprint: fingerprint) else {
            throw MaterializationError.staleAttempt
        }
        return fingerprint
    }

    private func pause(_ token: BookMaterializationToken) async {
        guard let pending = try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token, pending.phase != .ready else { return }
        _ = try? await persistence.transition(token: token, from: pending.phase, to: .paused)
    }

    private func digest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
