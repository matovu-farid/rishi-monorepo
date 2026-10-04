import Foundation

public enum BookImportPersistenceError: Error, Sendable, Equatable {
    case bookIDOccupied
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

public protocol ManagedFileVersionInspecting: Sendable {
    func managedFileVersion(at absoluteURL: URL, materializationRevision: UUID) throws -> ManagedFileVersion?
}

public struct RetiredBookMaterializationAttempt: Sendable, Equatable {
    public let token: BookMaterializationToken

    public init(token: BookMaterializationToken) {
        self.token = token
    }
}

public protocol BookImportPersistence: Sendable {
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration?
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken?
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken?
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken?
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization?
    /// Cleanup-only lookup remains available after the Book row and reading
    /// authorization have been deleted. The caller must already hold the
    /// admitted account deletion operation and validate the captured path.
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization?
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization?
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint?
    /// Persists a digest only while the same owned Book path, authorization,
    /// and managed-file version are still current.
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool
    func recordServerAcceptance(bookID: BookID, ownerID: UserID, expectedGeneration: UInt64, expectedContentRevision: UUID, acceptance: BookServerAcceptance) async throws -> Bool
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws
}

public extension BookImportPersistence {
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool { false }
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        try await pendingMaterialization(bookID: bookID, ownerID: ownerID)
    }
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool { false }
    func recordServerAcceptance(bookID: BookID, ownerID: UserID, expectedGeneration: UInt64, expectedContentRevision: UUID, acceptance: BookServerAcceptance) async throws -> Bool { false }
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool { false }
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool { false }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { false }
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? { nil }
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? { nil }

    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? {
        try await pendingMaterialization(bookID: bookID, ownerID: ownerID)
    }

    func reserveRegistration(book: Book, job: PendingBookMaterialization) async throws -> BookRegistration {
        try await reserveRegistration(book: book, job: job, candidate: nil)
    }

    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization) async throws -> BookRegistration? {
        try await joinOrRetryPending(ownerID: ownerID, sha256: sha256, newSource: newSource, retiredAttempt: nil)
    }
}
