import CryptoKit
import Darwin
import Foundation

public struct BookMaterializationCoordinator: Sendable {
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
    private let events: BookImportEvents?
    private let importInstrumentation: BookImportInstrumentation
    private let reprobeSelectedSource: @Sendable (URL, UUID) async throws -> (sha256: String, byteCount: Int64, version: ManagedFileVersion)

    public init(
        rootURL: URL,
        lifecycle: BookImportLifecycle,
        sourceRegistry: BookSourceRegistry,
        persistence: any BookImportPersistence,
        bookStore: any BookStore,
        currentGeneration: @escaping @Sendable () async -> UInt64?,
        isTombstoned: @escaping @Sendable (BookID) async -> Bool = { _ in false },
        copier: CoordinatedBookCopier = CoordinatedBookCopier(),
        events: BookImportEvents? = nil,
        reprobeSelectedSource: (@Sendable (URL, UUID) async throws -> (sha256: String, byteCount: Int64, version: ManagedFileVersion))? = nil,
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
        self.events = events
        self.importInstrumentation = importInstrumentation
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
        guard token.bookID == book.id, token.ownerID == book.userId,
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
        importInstrumentation.record(.bookRegistered, attemptID: token.attemptID)
        await events?.publish(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .registered(book)
        ))
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
                contentRevision: managed.fingerprint.version.materializationRevision,
                token: nil, requiresSecurityScope: false, observeChanges: false
            )
            return true
        } catch {
            lifecycle.retireBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            await lifecycle.drainBook(ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id)
            return false
        }
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
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        admission suppliedAdmission: BookImportMaterializationAdmission? = nil
    ) async throws -> BookFileFingerprint {
        // Acquire the canonical per-book attempt while the pre-reservation
        // owner gate is still held, then release the broad registration gate
        // before any suspension or copy work.
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
              initial.token == token, initial.phase == .registered else {
            throw MaterializationError.staleAttempt
        }
        guard try await persistence.transition(token: token, from: .registered, to: .copying) else {
            throw MaterializationError.staleAttempt
        }
        return try await materializeCopying(
            book: book, token: token, sourceURL: sourceURL,
            publishRegistration: publishRegistration,
            reuseRegisteredSource: reuseRegisteredSource,
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
            contentRevision: pending.sourceVersion.materializationRevision,
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
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        onRegistrationAccepted: (@Sendable () -> Void)? = nil,
        admission suppliedAdmission: BookImportMaterializationAdmission? = nil
    ) async throws -> BookRegistration {
        let oldToken = retiredAttempt.token
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
        guard oldToken.bookID == book.id, oldToken.ownerID == book.userId,
              newSource.token.bookID == book.id,
              newSource.token.ownerID == book.userId,
              lifecycle.admits(ownerID: newSource.token.ownerID, generation: newSource.token.accountGeneration),
              await currentGeneration() == newSource.token.accountGeneration else {
            throw MaterializationError.staleAttempt
        }
        await lifecycle.drainBook(ownerID: oldToken.ownerID, generation: oldToken.accountGeneration, bookID: oldToken.bookID)
        guard let attempt = lifecycle.admitBookMaterialization(newSource.token) else {
            throw MaterializationError.staleAttempt
        }
        defer { attempt.release() }
        registrationAdmission.release()
        guard let registration = try await persistence.joinOrRetryPending(
            ownerID: book.userId,
            sha256: newSource.expectedSHA256,
            newSource: newSource,
            retiredAttempt: retiredAttempt
        ), registration.disposition == .retried,
           let token = registration.token,
           token == newSource.token else {
            throw MaterializationError.staleAttempt
        }
        // The retry CAS now owns the persisted source path. Transfer its
        // directory before attempting lifecycle activation so a failed
        // activation leaves the retry available to recovery.
        onRegistrationAccepted?()
        guard lifecycle.activatePromotionAttempt(token) else {
            throw MaterializationError.staleAttempt
        }
        _ = try await materialize(
            book: registration.book,
            token: token,
            sourceURL: sourceURL,
            publishRegistration: publishRegistration,
            onSourceOwnerReleased: onSourceOwnerReleased
        )
        return registration
    }

    /// Resumes an attempt that `BookImportRecovery` adopted after validating
    /// its persisted inode and digest provenance.
    public func resumeRecovered(book: Book, token: BookMaterializationToken) async throws -> BookFileFingerprint {
        guard let attempt = lifecycle.admitBookMaterialization(token) else {
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
        onSourceOwnerReleased: (@Sendable () -> Void)? = nil,
        requiresSecurityScope: Bool = false,
        pending initial: PendingBookMaterialization
    ) async throws -> BookFileFingerprint {
        guard let operation = lifecycle.admitOwnerOperation(ownerID: token.ownerID, generation: token.accountGeneration) else {
            throw MaterializationError.staleAttempt
        }
        defer { operation.release() }
        if !reuseRegisteredSource {
            _ = try await sourceRegistry.registerSource(
                for: book,
                url: sourceURL,
                accountGeneration: token.accountGeneration,
                contentRevision: initial.sourceVersion.materializationRevision,
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
        let stagingURL = rootURL.appendingPathComponent(initial.stagingRelativePath).standardizedFileURL
        guard isContained(stagingURL) else { throw MaterializationError.staleAttempt }
        do {
            let staged = try await copier.copy(
                source: source,
                to: stagingURL,
                expectedSHA256: initial.expectedSHA256,
                expectedByteCount: initial.expectedByteCount,
                sourceVersion: initial.sourceVersion
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
            let fingerprint = try await lifecycle.withPromotionPermit(token: token) {
                try await self.promote(book: book, token: token, sourceURL: source.url, sourceVersion: initial.sourceVersion, artifact: staged)
            }
            await publishManagedReady(book: book, generation: token.accountGeneration, fingerprint: fingerprint)
            return fingerprint
        } catch {
            await pause(token)
            await sourceRegistry.failPendingSource(ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID, error: error)
            try? FileManager.default.removeItem(at: stagingURL)
            await publishFailed(token: token, retryableCode: "materialization_failed")
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
                guard try await self.persistence.claimPromotion(token: token, preparedFileIdentifier: preparedID, promotionRevision: revision) else {
                    throw MaterializationError.staleAttempt
                }
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
                let status = stagingURL.path.withCString { sourcePath in
                    destinationURL.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
                }
                guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }

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
        let destinationURL = rootURL.appendingPathComponent(pending.destinationRelativePath).standardizedFileURL
        guard isContained(destinationURL), let expectedID = pending.destinationFileIdentifier,
              let revision = pending.promotionRevision,
              try verifiedDestination(destinationURL, expectedID: expectedID, revision: revision, pending: pending),
              let finalVersion = try CoordinatedSourceProbe.version(at: destinationURL, revision: revision) else {
            throw MaterializationError.missingFileProvenance
        }
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: pending.expectedSHA256, version: finalVersion)
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
            contentRevision: fingerprint.version.materializationRevision,
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
        artifact: StagedBookArtifact
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
        guard try await persistence.claimPromotion(token: token, preparedFileIdentifier: preparedFileIdentifier, promotionRevision: promotionRevision) else {
            throw MaterializationError.staleAttempt
        }

        let destinationURL = rootURL.appendingPathComponent(pending.destinationRelativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destinationURL.path.hasPrefix(rootPath), destinationURL.path != rootURL.path else {
            throw MaterializationError.staleAttempt
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = artifact.url.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard let finalVersion = try CoordinatedSourceProbe.version(at: destinationURL, revision: promotionRevision),
              finalVersion.fileIdentifier == preparedFileIdentifier,
              finalVersion.byteCount == pending.expectedByteCount,
              try digest(at: destinationURL) == pending.expectedSHA256.lowercased() else {
            throw MaterializationError.promotedContentMismatch
        }
        guard try await persistence.recordPromoted(
            token: token,
            preparedFileIdentifier: preparedFileIdentifier,
            destinationFileIdentifier: preparedFileIdentifier,
            promotionRevision: promotionRevision
        ) else {
            throw MaterializationError.staleAttempt
        }
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: pending.expectedSHA256, version: finalVersion)
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
