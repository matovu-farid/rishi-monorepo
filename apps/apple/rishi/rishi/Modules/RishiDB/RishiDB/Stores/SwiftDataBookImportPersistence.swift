import Foundation
import SwiftData

public final class SwiftDataBookImportPersistence: BookImportPersistence, Sendable {
    public enum PersistenceError: Error, Sendable {
        case invalidReservation
        case unauthorized
        case bookIDOccupied
        case pendingJobConflict
        case staleCandidate
        case fingerprintOwnerMismatch
    }

    private let dbStore: RishiDBStore
    private let managedFileRootURL: URL?
    private let managedFileVersionInspector: any ManagedFileVersionInspecting

    public init(dbStore: RishiDBStore, managedFileRootURL: URL? = nil, managedFileVersionInspector: any ManagedFileVersionInspecting = FileManagedFileVersionInspector()) {
        self.dbStore = dbStore
        self.managedFileRootURL = managedFileRootURL?.standardizedFileURL
        self.managedFileVersionInspector = managedFileVersionInspector
    }

    public func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration {
        try await reserveRegistration(book: book, job: job, candidate: candidate, excludedBookIDs: [])
    }

    public func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?, excludedBookIDs: Set<BookID>) async throws -> BookRegistration {
        do {
        return try await dbStore.write { context in
            guard job.token.bookID == book.id, job.token.ownerID == book.userId,
                  job.phase == .registered, job.expectedByteCount >= 0,
                  job.expectedSHA256 == job.expectedSHA256.lowercased(),
                  job.destinationRelativePath == book.fileURL else {
                throw PersistenceError.invalidReservation
            }
            try Self.requireAccount(context, ownerID: book.userId, generation: job.token.accountGeneration)

            guard !excludedBookIDs.contains(book.id) else { throw PersistenceError.bookIDOccupied }
            if let authorization = try Self.readingEntity(context, bookID: book.id) {
                let existingBook = try Self.bookEntity(context, id: book.id)
                guard !authorization.tombstoned, existingBook != nil else { throw PersistenceError.bookIDOccupied }
            }

            if let candidate {
                guard !excludedBookIDs.contains(candidate.bookID), candidate.ownerID == book.userId, candidate.sha256 == job.expectedSHA256,
                      let candidateBook = try Self.bookEntity(context, id: candidate.bookID),
                      candidateBook.userId == candidate.ownerID,
                      let candidateValue = candidateBook.bookValue,
                      let fingerprint = try Self.fingerprintEntity(context, bookID: candidate.bookID),
                      fingerprint.ownerID == candidate.ownerID,
                      fingerprint.sha256 == candidate.sha256,
                      fingerprint.byteCount == job.expectedByteCount,
                      fingerprint.materializationRevision == candidate.fingerprintRevision,
                      fingerprint.value.version == candidate.observedManagedVersion,
                      candidateBook.fileURL == candidate.relativePath,
                      candidate.absoluteURL.isFileURL,
                      candidate.absoluteURL.path.hasPrefix("/") else {
                    throw PersistenceError.staleCandidate
                }
                if let pending = try Self.pendingEntity(context, bookID: candidate.bookID) {
                    guard Self.readyJob(pending, matches: fingerprint.value, relativePath: candidate.relativePath) else {
                        throw PersistenceError.staleCandidate
                    }
                }
                try Self.requireReading(context, bookID: candidate.bookID, ownerID: candidate.ownerID, generation: job.token.accountGeneration)
                guard let managedFileRootURL, managedFileRootURL.isFileURL else { throw PersistenceError.staleCandidate }
                let canonicalURL = managedFileRootURL.appendingPathComponent(candidateBook.fileURL).standardizedFileURL
                let rootPath = managedFileRootURL.path.hasSuffix("/") ? managedFileRootURL.path : managedFileRootURL.path + "/"
                guard canonicalURL.path.hasPrefix(rootPath),
                      candidate.absoluteURL.standardizedFileURL == canonicalURL else { throw PersistenceError.staleCandidate }
                let currentVersion = try managedFileVersionInspector.managedFileVersion(at: canonicalURL, materializationRevision: candidate.fingerprintRevision)
                guard currentVersion == candidate.observedManagedVersion,
                      currentVersion == fingerprint.value.version else { throw PersistenceError.staleCandidate }
                return BookRegistration(book: candidateValue, token: nil, disposition: .alreadyManaged)
            }

            var eligiblePending: PendingBookMaterializationEntity?
            for pending in try Self.pendingEntities(context, ownerID: book.userId) {
                guard pending.expectedSHA256 == job.expectedSHA256,
                      !excludedBookIDs.contains(pending.bookID),
                      let existingBook = try Self.bookEntity(context, id: pending.bookID),
                      existingBook.userId == book.userId,
                      let authorization = try Self.readingEntity(context, bookID: pending.bookID),
                      authorization.ownerID == book.userId, !authorization.revoked, !authorization.tombstoned else { continue }
                eligiblePending = pending
                break
            }
            if let pending = eligiblePending {
                guard let existingJob = pending.value,
                      let existingBook = try Self.bookEntity(context, id: pending.bookID),
                      existingBook.userId == book.userId,
                      let existingBookValue = existingBook.bookValue else { throw PersistenceError.pendingJobConflict }
                try Self.requireReading(context, bookID: pending.bookID, ownerID: book.userId, generation: job.token.accountGeneration)
                let disposition: BookRegistration.Disposition = Self.isJoinable(existingJob.phase.rawValue) && existingJob.token.accountGeneration == job.token.accountGeneration && existingJob.expectedByteCount == job.expectedByteCount
                    ? .joinedPending
                    : .retryRequired
                return BookRegistration(book: existingBookValue, token: existingJob.token, disposition: disposition)
            }

            if let existingBook = try Self.bookEntity(context, id: book.id) {
                guard existingBook.userId == book.userId else { throw PersistenceError.bookIDOccupied }
                if let existingJob = try Self.pendingEntity(context, bookID: book.id),
                   existingJob.ownerID == book.userId,
                   let existingValue = existingJob.value,
                   Self.isJoinable(existingValue.phase.rawValue),
                   existingValue.expectedSHA256 == job.expectedSHA256,
                   existingValue.expectedByteCount == job.expectedByteCount,
                   existingValue.token.accountGeneration == job.token.accountGeneration,
                   let existingBookValue = existingBook.bookValue {
                    try Self.requireReading(context, bookID: book.id, ownerID: book.userId, generation: job.token.accountGeneration)
                    return BookRegistration(book: existingBookValue, token: existingValue.token, disposition: .joinedPending)
                }
                throw PersistenceError.bookIDOccupied
            }

            context.insert(Self.makeBookEntity(book))
            context.insert(PendingBookMaterializationEntity(job))
            context.insert(BookReadingAuthorizationEntity(bookID: book.id, ownerID: book.userId, generation: job.token.accountGeneration, contentRevision: job.sourceVersion.materializationRevision, verifiedContentDigest: job.expectedSHA256.lowercased(), tombstoned: false))
            return BookRegistration(book: book, token: job.token, disposition: .registered)
        }
        } catch PersistenceError.bookIDOccupied {
            throw BookImportPersistenceError.bookIDOccupied
        }
    }

    /// Removes a registration that never became visible to readers. The
    /// token/phase CAS prevents a late source-validation failure from deleting
    /// a retried, materializing, or already-ready attempt.
    public func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool {
        try await dbStore.write { context in
            guard let pending = try Self.pendingEntity(context, bookID: token.bookID),
                  pending.ownerID == token.ownerID,
                  Self.matches(pending, token),
                  pending.phaseRawValue == BookMaterializationPhase.registered.rawValue,
                  let book = try Self.bookEntity(context, id: token.bookID),
                  book.userId == token.ownerID,
                  let authorization = try Self.readingEntity(context, bookID: token.bookID),
                  authorization.ownerID == token.ownerID,
                  authorization.tombstoned == false else { return false }
            context.delete(pending)
            context.delete(authorization)
            context.delete(book)
            return true
        }
    }

    public func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? {
        try await dbStore.write { context -> BookRegistration? in
            guard newSource.token.ownerID == ownerID, newSource.expectedSHA256 == sha256,
                  let pending = try Self.pendingEntities(context, ownerID: ownerID).first(where: {
                      $0.expectedSHA256 == sha256
                  }),
                  let job = pending.value else { return nil }
            guard newSource.token.bookID == job.token.bookID,
                  newSource.destinationRelativePath == job.destinationRelativePath,
                  let book = try Self.bookEntity(context, id: job.token.bookID), book.userId == ownerID,
                  let bookValue = book.bookValue else { return nil }
            try Self.requireAccount(context, ownerID: ownerID, generation: newSource.token.accountGeneration)
            try Self.requireReading(context, bookID: job.token.bookID, ownerID: ownerID, generation: newSource.token.accountGeneration)

            guard newSource.expectedByteCount == job.expectedByteCount else {
                return BookRegistration(book: bookValue, token: job.token, disposition: .retryRequired)
            }

            if job.phase == .ready { return nil }

            guard job.phase == .failed || job.phase == .cancelled || job.phase == .paused else {
                guard job.token.accountGeneration == newSource.token.accountGeneration else {
                    return BookRegistration(book: bookValue, token: job.token, disposition: .retryRequired)
                }
                return BookRegistration(book: bookValue, token: job.token, disposition: .joinedPending)
            }

            guard newSource.phase == .registered,
                  newSource.token.attemptID != job.token.attemptID,
                  retiredAttempt?.token == job.token else {
                return BookRegistration(book: bookValue, token: job.token, disposition: .retryRequired)
            }
            Self.replace(pending, with: newSource)
            return BookRegistration(book: bookValue, token: newSource.token, disposition: .retried)
        }
    }

    public func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool {
        try await dbStore.write { context in
            guard let job = try Self.pendingEntity(context, bookID: token.bookID),
                  Self.matches(job, token), job.phaseRawValue == from.rawValue else { return false }
            try Self.requireLiveBook(context, token: token)
            job.phaseRawValue = to.rawValue
            return true
        }
    }

    /// CAS-records a closed, digest-verified staging artifact before it can be
    /// claimed for promotion. File existence alone never advances readiness.
    public func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool {
        try await dbStore.write { context in
            guard let job = try Self.pendingEntity(context, bookID: token.bookID),
                  Self.matches(job, token),
                  job.phaseRawValue == BookMaterializationPhase.copying.rawValue,
                  artifacts.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame,
                  artifacts.byteCount == job.expectedByteCount,
                  artifacts.stagingRelativePath == job.stagingRelativePath,
                  artifacts.destinationRelativePath == job.destinationRelativePath,
                  let preparedFileIdentifier = artifacts.preparedFileIdentifier,
                  !preparedFileIdentifier.isEmpty,
                  artifacts.destinationFileIdentifier == nil,
                  artifacts.promotionRevision == nil else { return false }
            try Self.requireLiveBook(context, token: token)
            job.preparedFileIdentifier = preparedFileIdentifier
            job.phaseRawValue = BookMaterializationPhase.prepared.rawValue
            return true
        }
    }

    /// Persists the exact prepared inode and claim revision before the
    /// staging file is moved over the canonical destination.
    public func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool {
        try await dbStore.write { context in
            guard !preparedFileIdentifier.isEmpty,
                  let job = try Self.pendingEntity(context, bookID: token.bookID),
                  Self.matches(job, token),
                  job.phaseRawValue == BookMaterializationPhase.prepared.rawValue,
                  job.preparedFileIdentifier == preparedFileIdentifier else { return false }
            try Self.requireLiveBook(context, token: token)
            job.promotionRevision = promotionRevision
            job.phaseRawValue = BookMaterializationPhase.promoting.rawValue
            return true
        }
    }

    /// Records the final inode after the atomic same-volume move. The caller
    /// must verify bytes and stat provenance before this CAS succeeds.
    public func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool {
        try await dbStore.write { context in
            guard !preparedFileIdentifier.isEmpty,
                  destinationFileIdentifier == preparedFileIdentifier,
                  let job = try Self.pendingEntity(context, bookID: token.bookID),
                  Self.matches(job, token),
                  job.phaseRawValue == BookMaterializationPhase.promoting.rawValue,
                  job.preparedFileIdentifier == preparedFileIdentifier,
                  job.promotionRevision == promotionRevision else { return false }
            try Self.requireLiveBook(context, token: token)
            job.destinationFileIdentifier = destinationFileIdentifier
            job.phaseRawValue = BookMaterializationPhase.promoted.rawValue
            return true
        }
    }

    public func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool {
        try await dbStore.write { context in
            guard fingerprint.bookID == token.bookID, fingerprint.ownerID == token.ownerID,
                  let job = try Self.pendingEntity(context, bookID: token.bookID), Self.matches(job, token),
                  job.phaseRawValue == BookMaterializationPhase.promoted.rawValue,
                  let value = job.value,
                  value.expectedSHA256 == fingerprint.sha256,
                  value.expectedByteCount == fingerprint.version.byteCount,
                  let destinationFileIdentifier = value.destinationFileIdentifier,
                  let fingerprintFileIdentifier = fingerprint.version.fileIdentifier,
                  destinationFileIdentifier == fingerprintFileIdentifier,
                  let promotionRevision = value.promotionRevision,
                  promotionRevision == fingerprint.version.materializationRevision else { return false }
            try Self.requireLiveBook(context, token: token)
            guard let book = try Self.bookEntity(context, id: token.bookID), book.fileURL == value.destinationRelativePath else { return false }

            let priorFingerprint = try Self.fingerprintEntity(context, bookID: token.bookID)
            if let reading = try Self.readingEntity(context, bookID: token.bookID) {
                guard reading.ownerID == token.ownerID, !reading.revoked, !reading.tombstoned else { return false }
                if let priorDigest = reading.verifiedContentDigest ?? priorFingerprint?.sha256,
                   priorDigest.caseInsensitiveCompare(fingerprint.sha256) != .orderedSame {
                    reading.contentRevision = Self.rotatedReadingRevision(after: reading.contentRevision)
                }
                reading.verifiedContentDigest = fingerprint.sha256.lowercased()
            }

            if let existing = priorFingerprint {
                guard existing.ownerID == token.ownerID else { throw PersistenceError.fingerprintOwnerMismatch }
                let acceptance = fingerprint.serverAcceptance
                    ?? (existing.sha256 == fingerprint.sha256 ? existing.value.serverAcceptance : nil)
                existing.sha256 = fingerprint.sha256
                existing.byteCount = fingerprint.version.byteCount
                existing.modificationDate = fingerprint.version.modificationDate
                existing.fileIdentifier = fingerprint.version.fileIdentifier
                existing.materializationRevision = fingerprint.version.materializationRevision
                existing.serverAcceptanceSHA256 = acceptance?.sha256
                existing.acceptedOperationID = acceptance?.acceptedOperationID
                existing.acceptedAt = acceptance?.acceptedAt
            } else {
                context.insert(BookFileFingerprintEntity(fingerprint))
            }
            job.phaseRawValue = BookMaterializationPhase.ready.rawValue
            return true
        }
    }

    public func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool {
        try await dbStore.write { context in
            guard token.bookID == bookID,
                  let job = try Self.pendingEntity(context, bookID: bookID), Self.matches(job, token),
                  job.phaseRawValue == BookMaterializationPhase.ready.rawValue,
                  let book = try Self.bookEntity(context, id: bookID), book.userId == token.ownerID else { return false }
            try Self.requireLiveBook(context, token: token)
            book.coverPath = relativePath
            return true
        }
    }

    public func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? {
        try await dbStore.write { context in
            guard currentOwnerID == expectedToken.ownerID,
                  newAttemptID != expectedToken.attemptID,
                  let job = try Self.pendingEntity(context, bookID: expectedToken.bookID), Self.matches(job, expectedToken),
                  let phase = BookMaterializationPhase(rawValue: job.phaseRawValue),
                  [.registered, .copying, .prepared, .promoting, .promoted, .paused].contains(phase),
                  verifiedArtifacts.sha256 == job.expectedSHA256,
                  verifiedArtifacts.byteCount == job.expectedByteCount,
                  verifiedArtifacts.stagingRelativePath == job.stagingRelativePath,
                  verifiedArtifacts.destinationRelativePath == job.destinationRelativePath,
                  verifiedArtifacts.preparedFileIdentifier == job.preparedFileIdentifier,
                  verifiedArtifacts.destinationFileIdentifier == job.destinationFileIdentifier,
                  verifiedArtifacts.promotionRevision == job.promotionRevision else { return nil }
            try Self.requireAccount(context, ownerID: currentOwnerID, generation: currentGeneration)
            guard let reading = try Self.readingEntity(context, bookID: expectedToken.bookID),
                  reading.ownerID == currentOwnerID,
                  !reading.revoked,
                  !reading.tombstoned else { return nil }
            guard let book = try Self.bookEntity(context, id: expectedToken.bookID),
                  book.userId == currentOwnerID,
                  book.fileURL == job.destinationRelativePath else { return nil }

            let unprepared = [.registered, .copying, .paused].contains(phase)
                && job.preparedFileIdentifier == nil
                && job.destinationFileIdentifier == nil
                && job.promotionRevision == nil
            if unprepared {
                let canResumeSource: Bool
                switch BookSourceKind(rawValue: job.sourceKindRawValue) {
                case .securityScopedOriginal:
                    canResumeSource = !(job.sourceBookmark?.isEmpty ?? true)
                case .ownedStaging:
                    if let managedFileRootURL,
                       let relativePath = job.ownedSourceRelativePath,
                       !relativePath.hasPrefix("/"),
                       !relativePath.split(separator: "/").contains("..") {
                        let root = managedFileRootURL.standardizedFileURL
                        let sourceURL = root.appendingPathComponent(relativePath).standardizedFileURL
                        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                        let expectedVersion = ManagedFileVersion(
                            byteCount: job.sourceByteCount,
                            modificationDate: job.sourceModificationDate,
                            fileIdentifier: job.sourceFileIdentifier,
                            materializationRevision: job.sourceMaterializationRevision
                        )
                        let actualVersion = try? managedFileVersionInspector.managedFileVersion(
                            at: sourceURL,
                            materializationRevision: job.sourceMaterializationRevision
                        )
                        canResumeSource = sourceURL.path.hasPrefix(rootPath) && actualVersion == expectedVersion
                    } else {
                        canResumeSource = false
                    }
                case nil:
                    canResumeSource = false
                }
                job.stagingRelativePath = "Imports/\(newAttemptID.uuidString)/content.partial"
                job.preparedFileIdentifier = nil
                job.destinationFileIdentifier = nil
                job.promotionRevision = nil
                job.phaseRawValue = (canResumeSource ? BookMaterializationPhase.registered : BookMaterializationPhase.paused).rawValue
                job.retryableErrorCode = canResumeSource ? nil : "recovery_source_unavailable"
            }
            job.accountGenerationBits = Int64(bitPattern: currentGeneration)
            job.attemptID = newAttemptID
            reading.accountGenerationBits = Int64(bitPattern: currentGeneration)
            return BookMaterializationToken(ownerID: currentOwnerID, accountGeneration: currentGeneration, bookID: expectedToken.bookID, attemptID: newAttemptID)
        }
    }

    /// Retires a recoverable attempt whose staged/final artifact failed
    /// verification. This CAS reauthorizes the same live owner's book and
    /// resets only attempt-scoped provenance so a picker retry can reuse the
    /// canonical BookID under the current generation.
    public func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? {
        try await dbStore.write { context in
            guard currentOwnerID == expectedToken.ownerID,
                  newAttemptID != expectedToken.attemptID,
                  let job = try Self.pendingEntity(context, bookID: expectedToken.bookID),
                  Self.matches(job, expectedToken),
                  let phase = BookMaterializationPhase(rawValue: job.phaseRawValue),
                  [.registered, .copying, .prepared, .promoting, .promoted, .paused].contains(phase) else { return nil }
            try Self.requireAccount(context, ownerID: currentOwnerID, generation: currentGeneration)
            guard let reading = try Self.readingEntity(context, bookID: expectedToken.bookID),
                  reading.ownerID == currentOwnerID,
                  !reading.revoked,
                  !reading.tombstoned,
                  let book = try Self.bookEntity(context, id: expectedToken.bookID),
                  book.userId == currentOwnerID,
                  book.fileURL == job.destinationRelativePath else { return nil }

            job.accountGenerationBits = Int64(bitPattern: currentGeneration)
            job.attemptID = newAttemptID
            job.stagingRelativePath = "Imports/\(newAttemptID.uuidString)/content.partial"
            job.preparedFileIdentifier = nil
            job.destinationFileIdentifier = nil
            job.promotionRevision = nil
            job.phaseRawValue = BookMaterializationPhase.paused.rawValue
            job.retryableErrorCode = "recovery_artifact_invalid"
            reading.accountGenerationBits = Int64(bitPattern: currentGeneration)
            return BookMaterializationToken(ownerID: currentOwnerID, accountGeneration: currentGeneration, bookID: expectedToken.bookID, attemptID: newAttemptID)
        }
    }

    /// Idempotently advances authorization for a quarantined job waiting on a
    /// user-selected source. Its attempt remains stable across relogins.
    public func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? {
        try await dbStore.write { context in
            guard currentOwnerID == expectedToken.ownerID,
                  let job = try Self.pendingEntity(context, bookID: expectedToken.bookID),
                  Self.matches(job, expectedToken),
                  job.phaseRawValue == BookMaterializationPhase.paused.rawValue,
                  job.retryableErrorCode == "recovery_artifact_invalid"
                    || job.retryableErrorCode == "recovery_source_unavailable" else { return nil }
            try Self.requireAccount(context, ownerID: currentOwnerID, generation: currentGeneration)
            guard let reading = try Self.readingEntity(context, bookID: expectedToken.bookID),
                  reading.ownerID == currentOwnerID,
                  !reading.tombstoned,
                  let book = try Self.bookEntity(context, id: expectedToken.bookID),
                  book.userId == currentOwnerID,
                  book.fileURL == job.destinationRelativePath else { return nil }
            job.accountGenerationBits = Int64(bitPattern: currentGeneration)
            reading.accountGenerationBits = Int64(bitPattern: currentGeneration)
            return BookMaterializationToken(
                ownerID: currentOwnerID,
                accountGeneration: currentGeneration,
                bookID: expectedToken.bookID,
                attemptID: expectedToken.attemptID
            )
        }
    }

    public func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool {
        try await dbStore.write { context in
            guard !refreshedData.isEmpty,
                  let job = try Self.pendingEntity(context, bookID: token.bookID),
                  Self.matches(job, token),
                  job.sourceKindRawValue == BookSourceKind.securityScopedOriginal.rawValue,
                  let phase = BookMaterializationPhase(rawValue: job.phaseRawValue),
                  [.registered, .copying, .paused].contains(phase) else { return false }
            try Self.requireLiveBook(context, token: token)
            job.sourceBookmark = refreshedData
            return true
        }
    }

    /// Advances only the authorization generation for a completed managed
    /// artifact after the managed path and fingerprint have been revalidated.
    /// The completed Book, digest, destination inode, and revision stay intact.
    public func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool {
        try await dbStore.write { context in
            guard fingerprint.bookID == bookID, fingerprint.ownerID == ownerID,
                  let managedFileRootURL, managedFileRootURL.isFileURL,
                  let account = try Self.accountEntity(context, ownerID: ownerID),
                  account.accountGenerationBits == Int64(bitPattern: generation),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  let storedFingerprint = try Self.fingerprintEntity(context, bookID: bookID),
                  storedFingerprint.ownerID == ownerID,
                  storedFingerprint.value == fingerprint else { return false }
            let pending = try Self.pendingEntity(context, bookID: bookID)
            if let pending {
                guard pending.ownerID == ownerID,
                      Self.readyJob(pending, matches: fingerprint, relativePath: book.fileURL) else { return false }
            }

            let root = managedFileRootURL.standardizedFileURL
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard !book.fileURL.hasPrefix("/"),
                  !book.fileURL.split(separator: "/").contains("..") else { return false }
            let canonicalURL = root.appendingPathComponent(book.fileURL).standardizedFileURL
            guard canonicalURL.path.hasPrefix(rootPath),
                  let actualVersion = try managedFileVersionInspector.managedFileVersion(
                    at: canonicalURL,
                    materializationRevision: fingerprint.version.materializationRevision
                  ), actualVersion == fingerprint.version else { return false }

            let reading = try Self.readingEntity(context, bookID: bookID)
            if let reading {
                guard reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned else { return false }
                reading.accountGenerationBits = Int64(bitPattern: generation)
                reading.contentRevision = fingerprint.version.materializationRevision
                reading.verifiedContentDigest = fingerprint.sha256.lowercased()
            } else {
                context.insert(BookReadingAuthorizationEntity(
                    bookID: bookID,
                    ownerID: ownerID,
                    generation: generation,
                    contentRevision: fingerprint.version.materializationRevision,
                    verifiedContentDigest: fingerprint.sha256.lowercased(),
                    tombstoned: false
                ))
            }
            // Keep the completed attempt identity while bringing its durable
            // authorization token into the active account generation.
            pending?.accountGenerationBits = Int64(bitPattern: generation)
            return true
        }
    }

    public func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        try await dbStore.read { context in
            guard let job = try Self.pendingEntity(context, bookID: bookID), job.ownerID == ownerID,
                  let value = job.value else { return nil }
            try Self.requireAccount(context, ownerID: ownerID, generation: value.token.accountGeneration)
            try Self.requireReading(context, bookID: bookID, ownerID: ownerID, generation: value.token.accountGeneration)
            guard let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID else { return nil }
            return value
        }
    }

    /// Cleanup-only access intentionally survives Book-row and reading-auth
    /// deletion. Callers must hold the account deletion admission and use the
    /// returned token/path only for post-CAS filesystem cleanup.
    public func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        try await dbStore.read { context in
            guard let job = try Self.pendingEntity(context, bookID: bookID),
                  job.ownerID == ownerID,
                  let value = job.value,
                  value.token.bookID == bookID,
                  value.token.ownerID == ownerID else { return nil }
            return value
        }
    }

    public func pendingMaterializationsForDeletionCleanup(ownerID: UserID) async throws -> [PendingBookMaterialization] {
        try await dbStore.read { context in
            try Self.pendingEntities(context, ownerID: ownerID).compactMap { entity in
                guard let value = entity.value, value.token.ownerID == ownerID,
                      value.token.bookID == entity.bookID else { return nil }
                return value
            }
        }
    }

    public func isBookPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool {
        try await dbStore.read { context in
            guard let authorization = try Self.readingEntity(context, bookID: bookID),
                  authorization.ownerID == ownerID else { return false }
            return authorization.revoked && authorization.tombstoned
        }
    }

    /// Drops retained attempt metadata only after the caller has removed the
    /// captured managed/staging files. Token CAS preserves a newer retry.
    public func deletePendingMaterializationForDeletionCleanup(
        bookID: BookID,
        ownerID: UserID,
        expectedToken: BookMaterializationToken
    ) async throws -> Bool {
        try await dbStore.write { context in
            guard expectedToken.bookID == bookID,
                  expectedToken.ownerID == ownerID,
                  let job = try Self.pendingEntity(context, bookID: bookID),
                  job.ownerID == ownerID,
                  Self.matches(job, expectedToken) else { return false }
            context.delete(job)
            return true
        }
    }

    /// Recovery is the only path allowed to inspect a job from an older
    /// generation. It still requires the authenticated current account, the
    /// same book owner/path, and a non-tombstoned reading authorization.
    public func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? {
        try await dbStore.read { context in
            try Self.requireAccount(context, ownerID: ownerID, generation: currentGeneration)
            guard let job = try Self.pendingEntity(context, bookID: bookID), job.ownerID == ownerID,
                  let value = job.value,
                  let reading = try Self.readingEntity(context, bookID: bookID), reading.ownerID == ownerID,
                  !reading.tombstoned,
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  book.fileURL == value.destinationRelativePath else { return nil }
            return value
        }
    }

    public func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        try await dbStore.read { context in
            guard let entity = try Self.fingerprintEntity(context, bookID: bookID), entity.ownerID == ownerID,
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID else { return nil }
            let fingerprint = entity.value
            if let pending = try Self.pendingEntity(context, bookID: bookID),
               !Self.readyJob(pending, matches: fingerprint, relativePath: book.fileURL) {
                return nil
            }
            return fingerprint
        }
    }

    public func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool {
        false
    }

    public func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool {
        try await dbStore.write { context in
            guard fingerprint.version == expectedVersion,
                  let managedFileRootURL, managedFileRootURL.isFileURL,
                  let book = try Self.bookEntity(context, id: fingerprint.bookID),
                  book.userId == fingerprint.ownerID,
                  book.fileURL == expectedRelativePath,
                  let account = try Self.accountEntity(context, ownerID: fingerprint.ownerID), !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: expectedGeneration) else { return false }

            let reading = try Self.readingEntity(context, bookID: fingerprint.bookID)
            let priorFingerprint = try Self.fingerprintEntity(context, bookID: fingerprint.bookID)
            if let reading {
                guard reading.ownerID == fingerprint.ownerID,
                      !reading.revoked, !reading.tombstoned,
                      account.accountGenerationBits == reading.accountGenerationBits,
                      reading.accountGenerationBits == Int64(bitPattern: expectedGeneration) else { return false }
            }

            let rootPath = managedFileRootURL.standardizedFileURL.path.hasSuffix("/")
                ? managedFileRootURL.standardizedFileURL.path
                : managedFileRootURL.standardizedFileURL.path + "/"
            let canonicalURL = managedFileRootURL.appendingPathComponent(book.fileURL).standardizedFileURL
            guard canonicalURL.path.hasPrefix(rootPath),
                  let actualVersion = try managedFileVersionInspector.managedFileVersion(
                    at: canonicalURL,
                    materializationRevision: expectedVersion.materializationRevision
                  ), actualVersion == expectedVersion else { return false }

            if let pending = try Self.pendingEntity(context, bookID: fingerprint.bookID) {
                guard Self.readyJob(pending, matches: fingerprint, relativePath: expectedRelativePath) else { return false }
            }

            // Older durable imports predate the local reading authorization
            // entity. Seed it only for this live owner and current account
            // generation, in the same transaction as the digest cache write.
            if reading == nil {
                context.insert(BookReadingAuthorizationEntity(
                    bookID: fingerprint.bookID,
                    ownerID: fingerprint.ownerID,
                    generation: expectedGeneration,
                    contentRevision: expectedVersion.materializationRevision,
                    verifiedContentDigest: fingerprint.sha256.lowercased(),
                    tombstoned: false
                ))
            } else if let reading {
                if let priorDigest = reading.verifiedContentDigest ?? priorFingerprint?.sha256,
                   priorDigest.caseInsensitiveCompare(fingerprint.sha256) != .orderedSame {
                    reading.contentRevision = Self.rotatedReadingRevision(after: reading.contentRevision)
                }
                reading.verifiedContentDigest = fingerprint.sha256.lowercased()
            }

            let acceptance: BookServerAcceptance?
            if let existing = priorFingerprint,
               existing.ownerID == fingerprint.ownerID,
               existing.sha256 == fingerprint.sha256 {
                acceptance = existing.value.serverAcceptance
            } else {
                acceptance = nil
            }
            let value = BookFileFingerprint(
                bookID: fingerprint.bookID,
                ownerID: fingerprint.ownerID,
                sha256: fingerprint.sha256.lowercased(),
                version: expectedVersion,
                serverAcceptance: acceptance
            )
            if let existing = try Self.fingerprintEntity(context, bookID: fingerprint.bookID) {
                guard existing.ownerID == fingerprint.ownerID else { return false }
                existing.sha256 = value.sha256
                existing.byteCount = value.version.byteCount
                existing.modificationDate = value.version.modificationDate
                existing.fileIdentifier = value.version.fileIdentifier
                existing.materializationRevision = value.version.materializationRevision
                existing.serverAcceptanceSHA256 = value.serverAcceptance?.sha256
                existing.acceptedOperationID = value.serverAcceptance?.acceptedOperationID
                existing.acceptedAt = value.serverAcceptance?.acceptedAt
            } else {
                context.insert(BookFileFingerprintEntity(value))
            }
            return true
        }
    }

    /// Stores server acknowledgement only while the authenticated account and
    /// the locally verified reading authorization still identify this exact
    /// content revision. A late upload response cannot bless a newer file or
    /// a different account generation.
    public func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit? {
        try await dbStore.read { context in
            guard let account = try Self.accountEntity(context, ownerID: ownerID), !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: generation),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  let reading = try Self.readingEntity(context, bookID: bookID),
                  reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned,
                  reading.accountGenerationBits == Int64(bitPattern: generation) else { return nil }
            return BookReadingPermit(ownerID: ownerID, accountGeneration: generation, bookID: bookID, contentRevision: reading.contentRevision)
        }
    }

    public func readingPermit(
        forManagedFingerprint expectedFingerprint: BookFileFingerprint,
        expectedRelativePath: String,
        generation: UInt64
    ) async throws -> BookReadingPermit? {
        try await dbStore.read { context in
            let ownerID = expectedFingerprint.ownerID
            let bookID = expectedFingerprint.bookID
            guard let account = try Self.accountEntity(context, ownerID: ownerID), !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: generation),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  book.fileURL == expectedRelativePath,
                  !expectedRelativePath.hasPrefix("/"),
                  !expectedRelativePath.split(separator: "/").contains(".."),
                  let stored = try Self.fingerprintEntity(context, bookID: bookID),
                  stored.ownerID == ownerID,
                  stored.sha256.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  stored.byteCount == expectedFingerprint.version.byteCount,
                  stored.modificationDate == expectedFingerprint.version.modificationDate,
                  stored.fileIdentifier == expectedFingerprint.version.fileIdentifier,
                  stored.materializationRevision == expectedFingerprint.version.materializationRevision,
                  let reading = try Self.readingEntity(context, bookID: bookID),
                  reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned,
                  reading.accountGenerationBits == Int64(bitPattern: generation),
                  reading.verifiedContentDigest?.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame else { return nil }

            if let pending = try Self.pendingEntity(context, bookID: bookID) {
                guard pending.ownerID == ownerID,
                      pending.accountGenerationBits == Int64(bitPattern: generation),
                      Self.readyJob(pending, matches: expectedFingerprint, relativePath: expectedRelativePath) else { return nil }
            }

            guard let managedFileRootURL, managedFileRootURL.isFileURL else { return nil }
            let root = managedFileRootURL.standardizedFileURL
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let managedURL = root.appendingPathComponent(expectedRelativePath).standardizedFileURL
            guard managedURL.path.hasPrefix(rootPath),
                  try managedFileVersionInspector.managedFileVersion(
                    at: managedURL,
                    materializationRevision: expectedFingerprint.version.materializationRevision
                  ) == expectedFingerprint.version else { return nil }

            return BookReadingPermit(
                ownerID: ownerID,
                accountGeneration: generation,
                bookID: bookID,
                contentRevision: reading.contentRevision
            )
        }
    }

    public func recordServerAcceptance(
        permit: BookReadingPermit,
        expectedFingerprint: BookFileFingerprint,
        acceptance: BookServerAcceptance
    ) async throws -> Bool {
        try await dbStore.write { context in
            let bookID = permit.bookID
            let ownerID = permit.ownerID
            let expectedGeneration = permit.accountGeneration
            guard expectedFingerprint.bookID == bookID,
                  expectedFingerprint.ownerID == ownerID,
                  acceptance.sha256.count == 64,
                  acceptance.sha256.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  let account = try Self.accountEntity(context, ownerID: ownerID),
                  !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: expectedGeneration),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  let reading = try Self.readingEntity(context, bookID: bookID),
                  reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned,
                  reading.accountGenerationBits == Int64(bitPattern: expectedGeneration),
                  reading.contentRevision == permit.contentRevision,
                  reading.verifiedContentDigest?.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  let fingerprint = try Self.fingerprintEntity(context, bookID: bookID),
                  fingerprint.ownerID == ownerID,
                  fingerprint.sha256.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  fingerprint.byteCount == expectedFingerprint.version.byteCount,
                  fingerprint.modificationDate == expectedFingerprint.version.modificationDate,
                  fingerprint.fileIdentifier == expectedFingerprint.version.fileIdentifier,
                  fingerprint.materializationRevision == expectedFingerprint.version.materializationRevision else { return false }
            guard let managedFileRootURL, managedFileRootURL.isFileURL,
                  !book.fileURL.hasPrefix("/"),
                  !book.fileURL.split(separator: "/").contains("..") else { return false }
            let root = managedFileRootURL.standardizedFileURL
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let managedURL = root.appendingPathComponent(book.fileURL).standardizedFileURL
            guard managedURL.path.hasPrefix(rootPath),
                  try managedFileVersionInspector.managedFileVersion(
                    at: managedURL,
                    materializationRevision: expectedFingerprint.version.materializationRevision
                  ) == expectedFingerprint.version else { return false }
            if let pending = try Self.pendingEntity(context, bookID: bookID) {
                guard Self.readyJob(pending, matches: expectedFingerprint, relativePath: book.fileURL) else { return false }
            }
            fingerprint.serverAcceptanceSHA256 = acceptance.sha256.lowercased()
            fingerprint.acceptedOperationID = acceptance.acceptedOperationID
            fingerprint.acceptedAt = acceptance.acceptedAt
            return true
        }
    }

    public func recordServerAcceptance(
        accountPermit: AccountMutationPermit,
        expectedFingerprint: BookFileFingerprint,
        acceptance: BookServerAcceptance
    ) async throws -> Bool {
        try await dbStore.write { context in
            let ownerID = accountPermit.ownerID
            let generation = accountPermit.accountGeneration
            let bookID = expectedFingerprint.bookID
            guard expectedFingerprint.ownerID == ownerID,
                  acceptance.sha256.count == 64,
                  acceptance.sha256.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  let account = try Self.accountEntity(context, ownerID: ownerID), !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: generation),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  let reading = try Self.readingEntity(context, bookID: bookID),
                  reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned,
                  reading.accountGenerationBits == Int64(bitPattern: generation),
                  reading.verifiedContentDigest?.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  let fingerprint = try Self.fingerprintEntity(context, bookID: bookID),
                  fingerprint.ownerID == ownerID,
                  fingerprint.sha256.caseInsensitiveCompare(expectedFingerprint.sha256) == .orderedSame,
                  fingerprint.byteCount == expectedFingerprint.version.byteCount,
                  fingerprint.modificationDate == expectedFingerprint.version.modificationDate,
                  fingerprint.fileIdentifier == expectedFingerprint.version.fileIdentifier,
                  fingerprint.materializationRevision == expectedFingerprint.version.materializationRevision,
                  let managedFileRootURL, managedFileRootURL.isFileURL,
                  !book.fileURL.hasPrefix("/"),
                  !book.fileURL.split(separator: "/").contains("..") else { return false }
            let root = managedFileRootURL.standardizedFileURL
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let managedURL = root.appendingPathComponent(book.fileURL).standardizedFileURL
            guard managedURL.path.hasPrefix(rootPath),
                  try managedFileVersionInspector.managedFileVersion(
                    at: managedURL,
                    materializationRevision: expectedFingerprint.version.materializationRevision
                  ) == expectedFingerprint.version else { return false }
            if let pending = try Self.pendingEntity(context, bookID: bookID) {
                guard Self.readyJob(pending, matches: expectedFingerprint, relativePath: book.fileURL) else { return false }
            }
            fingerprint.serverAcceptanceSHA256 = acceptance.sha256.lowercased()
            fingerprint.acceptedOperationID = acceptance.acceptedOperationID
            fingerprint.acceptedAt = acceptance.acceptedAt
            return true
        }
    }

    public func recordServerAcceptance(
        bookID: BookID,
        ownerID: UserID,
        expectedGeneration: UInt64,
        expectedContentRevision: UUID,
        acceptance: BookServerAcceptance
    ) async throws -> Bool {
        try await dbStore.write { context in
            guard acceptance.sha256.count == 64,
                  let account = try Self.accountEntity(context, ownerID: ownerID),
                  !account.revoked,
                  account.accountGenerationBits == Int64(bitPattern: expectedGeneration),
                  let book = try Self.bookEntity(context, id: bookID), book.userId == ownerID,
                  let reading = try Self.readingEntity(context, bookID: bookID),
                  reading.ownerID == ownerID, !reading.revoked, !reading.tombstoned,
                  reading.accountGenerationBits == Int64(bitPattern: expectedGeneration),
                  reading.contentRevision == expectedContentRevision,
                  let fingerprint = try Self.fingerprintEntity(context, bookID: bookID),
                  fingerprint.ownerID == ownerID,
                  fingerprint.sha256.caseInsensitiveCompare(acceptance.sha256) == .orderedSame,
                  fingerprint.materializationRevision == expectedContentRevision else { return false }
            fingerprint.serverAcceptanceSHA256 = acceptance.sha256.lowercased()
            fingerprint.acceptedOperationID = acceptance.acceptedOperationID
            fingerprint.acceptedAt = acceptance.acceptedAt
            return true
        }
    }

    public func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {
        if let generation {
            try await dbStore.activateAccountMutation(permit: AccountMutationPermit(ownerID: ownerID, accountGeneration: generation))
            return
        }
        if let generation = try await dbStore.read({ context in
            try Self.accountEntity(context, ownerID: ownerID).map { UInt64(bitPattern: $0.accountGenerationBits) }
        }) {
            try await dbStore.revokeAccountMutation(permit: AccountMutationPermit(ownerID: ownerID, accountGeneration: generation))
            return
        }
        try await dbStore.write { context in
            if let existing = try Self.accountEntity(context, ownerID: ownerID) { context.delete(existing) }
        }
    }

    public func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {
        let permit = BookReadingPermit(ownerID: ownerID, accountGeneration: generation, bookID: bookID, contentRevision: contentRevision)
        if !tombstoned {
            try await dbStore.activateBookReading(permit: permit)
            return
        }
        try await dbStore.revokeBookReading(permit: permit, tombstone: true)
    }

    private static func makeBookEntity(_ book: Book) -> BookEntity {
        BookEntity(id: book.id, userId: book.userId, title: book.title, author: book.author, formatTypeRawValue: book.formatType.rawValue, addedAt: book.addedAt, openedAt: book.openedAt, fileURL: book.fileURL, coverPath: book.coverPath, positionId: book.positionId, conversationId: book.conversationId, chapterIndexContentVersion: book.chapterIndexContentVersion)
    }

    private static func bookEntity(_ context: ModelContext, id: BookID) throws -> BookEntity? {
        var descriptor = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func pendingEntity(_ context: ModelContext, bookID: BookID) throws -> PendingBookMaterializationEntity? {
        var descriptor = FetchDescriptor<PendingBookMaterializationEntity>(predicate: #Predicate { $0.bookID == bookID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func pendingEntities(_ context: ModelContext, ownerID: UserID) throws -> [PendingBookMaterializationEntity] {
        try context.fetch(FetchDescriptor<PendingBookMaterializationEntity>(predicate: #Predicate { $0.ownerID == ownerID }))
    }

    private static func fingerprintEntity(_ context: ModelContext, bookID: BookID) throws -> BookFileFingerprintEntity? {
        var descriptor = FetchDescriptor<BookFileFingerprintEntity>(predicate: #Predicate { $0.bookID == bookID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func accountEntity(_ context: ModelContext, ownerID: UserID) throws -> AccountMutationAuthorizationEntity? {
        var descriptor = FetchDescriptor<AccountMutationAuthorizationEntity>(predicate: #Predicate { $0.ownerID == ownerID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func readingEntity(_ context: ModelContext, bookID: BookID) throws -> BookReadingAuthorizationEntity? {
        var descriptor = FetchDescriptor<BookReadingAuthorizationEntity>(predicate: #Predicate { $0.bookID == bookID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func requireAccount(_ context: ModelContext, ownerID: UserID, generation: UInt64) throws {
        guard let entity = try accountEntity(context, ownerID: ownerID),
              UInt64(bitPattern: entity.accountGenerationBits) == generation,
              !entity.revoked else { throw PersistenceError.unauthorized }
    }

    private static func requireReading(_ context: ModelContext, bookID: BookID, ownerID: UserID, generation: UInt64) throws {
        guard let entity = try readingEntity(context, bookID: bookID), entity.ownerID == ownerID,
              UInt64(bitPattern: entity.accountGenerationBits) == generation, !entity.revoked, !entity.tombstoned else { throw PersistenceError.unauthorized }
    }

    private static func requireLiveBook(_ context: ModelContext, token: BookMaterializationToken) throws {
        try requireAccount(context, ownerID: token.ownerID, generation: token.accountGeneration)
        try requireReading(context, bookID: token.bookID, ownerID: token.ownerID, generation: token.accountGeneration)
        guard let book = try bookEntity(context, id: token.bookID), book.userId == token.ownerID else { throw PersistenceError.unauthorized }
    }

    private static func matches(_ entity: PendingBookMaterializationEntity, _ token: BookMaterializationToken) -> Bool {
        entity.bookID == token.bookID && entity.ownerID == token.ownerID &&
            UInt64(bitPattern: entity.accountGenerationBits) == token.accountGeneration && entity.attemptID == token.attemptID
    }

    private static func isJoinable(_ phaseRawValue: String) -> Bool {
        guard let phase = BookMaterializationPhase(rawValue: phaseRawValue) else { return false }
        return phase != .ready && phase != .failed && phase != .cancelled && phase != .paused
    }

    private static func readyJob(
        _ entity: PendingBookMaterializationEntity,
        matches fingerprint: BookFileFingerprint,
        relativePath: String
    ) -> Bool {
        guard entity.phaseRawValue == BookMaterializationPhase.ready.rawValue,
              let job = entity.value else { return false }
        return entity.bookID == fingerprint.bookID
            && entity.ownerID == fingerprint.ownerID
            && job.expectedSHA256.caseInsensitiveCompare(fingerprint.sha256) == .orderedSame
            && job.expectedByteCount == fingerprint.version.byteCount
            && job.destinationRelativePath == relativePath
            && job.destinationFileIdentifier == fingerprint.version.fileIdentifier
            && job.promotionRevision == fingerprint.version.materializationRevision
    }

    private static func rotatedReadingRevision(after revision: UUID) -> UUID {
        var next = UUID()
        while next == revision { next = UUID() }
        return next
    }

    private static func replace(_ entity: PendingBookMaterializationEntity, with value: PendingBookMaterialization) {
        entity.ownerID = value.token.ownerID
        entity.accountGenerationBits = Int64(bitPattern: value.token.accountGeneration)
        entity.attemptID = value.token.attemptID
        entity.sourceKindRawValue = value.sourceKind.rawValue
        entity.sourceBookmark = value.sourceBookmark
        entity.ownedSourceRelativePath = value.ownedSourceRelativePath
        entity.sourceByteCount = value.sourceVersion.byteCount
        entity.sourceModificationDate = value.sourceVersion.modificationDate
        entity.sourceFileIdentifier = value.sourceVersion.fileIdentifier
        entity.sourceMaterializationRevision = value.sourceVersion.materializationRevision
        entity.expectedSHA256 = value.expectedSHA256
        entity.expectedByteCount = value.expectedByteCount
        entity.stagingRelativePath = value.stagingRelativePath
        entity.destinationRelativePath = value.destinationRelativePath
        entity.phaseRawValue = value.phase.rawValue
        entity.retryableErrorCode = value.retryableErrorCode
        entity.preparedFileIdentifier = value.preparedFileIdentifier
        entity.destinationFileIdentifier = value.destinationFileIdentifier
        entity.promotionRevision = value.promotionRevision
    }
}

public struct FileManagedFileVersionInspector: ManagedFileVersionInspecting {
    public init() {}

    public func managedFileVersion(at absoluteURL: URL, materializationRevision: UUID) throws -> ManagedFileVersion? {
        guard absoluteURL.isFileURL, absoluteURL.path.hasPrefix("/") else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: absoluteURL.path)
            guard let size = attributes[.size] as? NSNumber,
            let modificationDate = attributes[.modificationDate] as? Date else { return nil }
            let volumeID = attributes[.systemNumber] as? NSNumber
            let fileID = attributes[.systemFileNumber] as? NSNumber
            let identifier: String?
            if let volumeID, let fileID {
                identifier = "\(volumeID):\(fileID)"
            } else {
                identifier = nil
            }
            return ManagedFileVersion(byteCount: size.int64Value, modificationDate: modificationDate, fileIdentifier: identifier, materializationRevision: materializationRevision)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
