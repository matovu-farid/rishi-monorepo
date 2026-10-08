import Foundation

public enum BookImportPersistenceError: Error, Sendable, Equatable {
    case bookIDOccupied
    case sampleRepairUnsupported
}

public struct BookRegistration: Sendable {
    public enum Disposition: Sendable, Equatable {
        case registered, joinedPending, retryRequired, retried, alreadyManaged
    }

    public let book: Book
    public let token: BookMaterializationToken?
    public let disposition: Disposition

    public init(book: Book, token: BookMaterializationToken?, disposition: Disposition) {
        self.book = book
        self.token = token
        self.disposition = disposition
    }
}

public struct BookImportCandidateSnapshot: Sendable, Equatable {
    public let bookID: BookID
    public let ownerID: UserID
    public let relativePath: String
    public let sha256: String
    public let fingerprintRevision: UUID
    public let observedManagedVersion: ManagedFileVersion
    public let absoluteURL: URL

    public init(bookID: BookID, ownerID: UserID, relativePath: String, sha256: String, fingerprintRevision: UUID, observedManagedVersion: ManagedFileVersion, absoluteURL: URL) {
        self.bookID = bookID
        self.ownerID = ownerID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.fingerprintRevision = fingerprintRevision
        self.observedManagedVersion = observedManagedVersion
        self.absoluteURL = absoluteURL
    }
}

public struct SampleRepairReservationRequest: Sendable {
    public let expectedBook: Book
    public let expectedFingerprint: BookFileFingerprint
    public let canonicalManagedURL: URL
    public let expectedManagedFileVersion: ManagedFileVersion?
    public let expectedPriorPendingToken: BookMaterializationToken?
    public let job: PendingBookMaterialization

    public init(expectedBook: Book, expectedFingerprint: BookFileFingerprint, canonicalManagedURL: URL, expectedManagedFileVersion: ManagedFileVersion?, expectedPriorPendingToken: BookMaterializationToken?, job: PendingBookMaterialization) {
        self.expectedBook = expectedBook
        self.expectedFingerprint = expectedFingerprint
        self.canonicalManagedURL = canonicalManagedURL
        self.expectedManagedFileVersion = expectedManagedFileVersion
        self.expectedPriorPendingToken = expectedPriorPendingToken
        self.job = job
    }
}

public enum SampleRepairReservation: Sendable {
    case reserved(BookRegistration)
    case alreadyManaged(BookFileFingerprint)
    case reconciled(BookFileFingerprint)
}

public enum SampleRepairParkingOutcome: Sendable, Equatable {
    case parked
    case supersededOrFenced
    case writeFailed
}

public protocol ManagedFileVersionInspecting: Sendable {
    func managedFileVersion(at absoluteURL: URL, materializationRevision: UUID) throws -> ManagedFileVersion?
}

public struct RetiredBookMaterializationAttempt: Sendable, Equatable {
    public let token: BookMaterializationToken

    public init(token: BookMaterializationToken) {
        self.token = token
    }
}

/// Read-only snapshot of a retryable persisted attempt. Its permit describes
/// the old authorization row and must not be admitted for current-generation
/// reads or writes.
public struct BookImportRetryExpectation: Sendable, Equatable {
    public let book: Book
    public let pending: PendingBookMaterialization
    public let readingPermit: BookReadingPermit
    public let canonicalSHA256: String?

    public init(book: Book, pending: PendingBookMaterialization, readingPermit: BookReadingPermit, canonicalSHA256: String?) {
        self.book = book
        self.pending = pending
        self.readingPermit = readingPermit
        self.canonicalSHA256 = canonicalSHA256
    }
}

/// Digest lookup and generation-bound caching used by fingerprint verification.
public protocol BookFingerprintPersistence: Sendable {
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint?
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization?
    /// Persists a digest only while the same owned Book path, authorization,
    /// and managed-file version are still current.
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool
}

/// Canonical read authorization and source transitions used by the source registry.
public protocol BookReadingSourcePersistence: BookFingerprintPersistence {
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool
    /// Returns the canonical reading authority only for the currently admitted
    /// account generation. Adapters without persisted authorization fail closed.
    func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit?
    /// Returns the canonical authority only while this exact managed fingerprint
    /// and Book path remain current in the same persistence read.
    func readingPermit(forManagedFingerprint fingerprint: BookFileFingerprint, expectedRelativePath: String, generation: UInt64) async throws -> BookReadingPermit?
}

public protocol BookImportPersistence: BookReadingSourcePersistence {
    func reserveSampleRepair(_ request: SampleRepairReservationRequest) async throws -> SampleRepairReservation
    func parkSampleRepair(book: Book, token: BookMaterializationToken) async -> SampleRepairParkingOutcome
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?, excludedBookIDs: Set<BookID>) async throws -> BookRegistration
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration?
    func retryExpectation(bookID: BookID, ownerID: UserID, accountPermit: AccountMutationPermit) async throws -> BookImportRetryExpectation?
    func retryPendingMaterialization(expected: BookImportRetryExpectation, accountPermit: AccountMutationPermit, newSource: PendingBookMaterialization, verifiedSourceSHA256: String, verifiedSourceByteCount: Int64, verifiedSourceVersion: ManagedFileVersion, retiredAttempt: RetiredBookMaterializationAttempt) async throws -> BookRegistration?
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken?
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken?
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken?
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool
    /// Cleanup-only lookup remains available after the Book row and reading
    /// authorization have been deleted. The caller must already hold the
    /// admitted account deletion operation and validate the captured path.
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization?
    func pendingMaterializationsForDeletionCleanup(ownerID: UserID) async throws -> [PendingBookMaterialization]
    func isBookPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization?
    func sampleRepairFingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint?
    func recordServerAcceptance(permit: BookReadingPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool
    /// Temporary inbound bridge for a newly verified row that had no reading
    /// permit before its download began. Existing rows must use the book permit.
    func recordServerAcceptance(accountPermit: AccountMutationPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws
}

public extension BookImportPersistence {
    func reserveSampleRepair(_ request: SampleRepairReservationRequest) async throws -> SampleRepairReservation {
        throw BookImportPersistenceError.sampleRepairUnsupported
    }

    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?, excludedBookIDs: Set<BookID>) async throws -> BookRegistration {
        try await reserveRegistration(book: book, job: job, candidate: candidate.flatMap { excludedBookIDs.contains($0.bookID) ? nil : $0 })
    }

    func reserveRegistration(book: Book, job: PendingBookMaterialization) async throws -> BookRegistration {
        try await reserveRegistration(book: book, job: job, candidate: nil)
    }

    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization) async throws -> BookRegistration? {
        try await joinOrRetryPending(ownerID: ownerID, sha256: sha256, newSource: newSource, retiredAttempt: nil)
    }
}
