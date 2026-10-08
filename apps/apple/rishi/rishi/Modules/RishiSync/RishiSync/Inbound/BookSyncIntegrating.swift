import Foundation

/// Required book-domain operations consumed by inbound sync. Canonical LWW,
/// metadata CAS and position acknowledgement stay with ChangeApplier.
public protocol BookSyncIntegrating: Sendable {
    func currentUserId() async -> UserID?
    func ensureAccount(_ expectedUserId: UserID?) async throws
    func captureAccountPermit(ownerID: UserID) async throws -> AccountMutationPermit?
    func ensureCommitAuthority(_ permit: AccountMutationPermit?, expectedUserId: UserID?) async throws
    func prepareSourceReplacement(_ bookID: BookID, permit: AccountMutationPermit?) async throws -> BookSourceReplacementToken?
    func completeSourceReplacement(_ token: BookSourceReplacementToken) async throws
    func abortSourceReplacement(_ token: BookSourceReplacementToken) async
    func materialize(_ book: Book, r2Key: String?, remoteFile: InboundBookFileMetadata?, permit: AccountMutationPermit?) async throws -> VerifiedDownloadedBook?
    func admitCommit(_ permit: AccountMutationPermit?) async throws -> BookImportOperationLease?
    func persistFingerprint(_ fingerprint: BookFileFingerprint, for book: Book, generation: UInt64?) async -> Bool
    func withDeletionAdmission(ownerID: UserID?, operation: @Sendable (UInt64?) async throws -> Void) async throws
    func retireBookForDeletion(_ bookID: BookID, ownerID: UserID?, generation: UInt64?) async throws -> BookDeletionRetirementWitness?
    func prepareDeletionCleanup(_ bookID: BookID, ownerID: UserID?, existingBook: Book?) async throws -> (@Sendable () async throws -> Void)?
    func deferDeletionCleanup(_ witness: BookDeletionRetirementWitness, cleanup: @escaping @Sendable () async throws -> Void)
    func restoreAfterFailedRetirement(_ book: Book, generation: UInt64?) async -> Bool
    func scheduleRecovery(ownerID: UserID, generation: UInt64) async
    func activateBook(_ bookID: BookID, permit: AccountMutationPermit?) async
    func managedFingerprint(_ book: Book) async -> BookFileFingerprint?
    func readingPermit(_ book: Book) async -> BookReadingPermit?
    func contentDigest(_ book: Book, fallbackFingerprint: BookFileFingerprint?) async -> String?
    func hasPendingMaterialization(_ book: Book) async -> Bool
    func persistAcceptance(_ acceptance: BookServerAcceptance, permit: BookReadingPermit, fingerprint: BookFileFingerprint) async -> Bool
    func persistAcceptance(_ acceptance: BookServerAcceptance, permit: AccountMutationPermit, fingerprint: BookFileFingerprint) async -> Bool
}

struct BookSyncAccountChanged: Error, CustomStringConvertible {
    var description: String { "account switched during inbound sync" }
}
