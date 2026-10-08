import Foundation
@testable import rishi

/// Explicit metadata-only fixture. Each controlled operation has a concrete
/// outcome; individual tests replace the effects that their scenario exercises.
/// This implementation is test-target only and cannot enter production assembly.
struct TestBookSyncIntegration: BookSyncIntegrating {
    var userIdProvider: @Sendable () async -> UserID? = { nil }
    var accountIsActive: @Sendable () async -> Bool = { true }
    var capturePermitOperation: @Sendable (UserID) async throws -> AccountMutationPermit? = { _ in nil }
    var validatePermitOperation: @Sendable (AccountMutationPermit?) async throws -> Void = { _ in }
    var prepareReplacementOperation: @Sendable (BookID, AccountMutationPermit?) async throws -> BookSourceReplacementToken? = { _, _ in nil }
    var completeReplacementOperation: @Sendable (BookSourceReplacementToken) async throws -> Void = { _ in throw BookImportPromotionError.retired }
    var abortReplacementOperation: @Sendable (BookSourceReplacementToken) async -> Void = { _ in }
    var materializeOperation: @Sendable (Book, String?, InboundBookFileMetadata?, AccountMutationPermit?) async throws -> VerifiedDownloadedBook? = { _, _, _, _ in nil }
    var admitCommitOperation: @Sendable (AccountMutationPermit?) async throws -> BookImportOperationLease? = { _ in nil }
    var fingerprintOperation: @Sendable (BookFileFingerprint, Book, UInt64?) async -> Bool = { _, _, _ in false }
    var deletionAdmissionOperation: @Sendable (UserID?, @Sendable (UInt64?) async throws -> Void) async throws -> Void = { _, operation in try await operation(nil) }
    var retirementOperation: @Sendable (BookID, UserID?, UInt64?) async throws -> BookDeletionRetirementWitness? = { _, _, _ in nil }
    var cleanupOperation: @Sendable (BookID, UserID?, Book?) async throws -> (@Sendable () async throws -> Void)? = { _, _, _ in nil }
    var deferredCleanupOperation: @Sendable (BookDeletionRetirementWitness, @escaping @Sendable () async throws -> Void) -> Void = { _, _ in }
    var restoreOperation: @Sendable (Book, UInt64?) async -> Bool = { _, _ in false }
    var recoveryOperation: @Sendable (UserID, UInt64) async -> Void = { _, _ in }
    var activationOperation: @Sendable (BookID, AccountMutationPermit?) async -> Void = { _, _ in }
    var managedFingerprintOperation: @Sendable (Book) async -> BookFileFingerprint? = { _ in nil }
    var readingPermitOperation: @Sendable (Book) async -> BookReadingPermit? = { _ in nil }
    var digestOperation: @Sendable (Book, BookFileFingerprint?) async -> String? = { _, fingerprint in fingerprint?.sha256 }
    var pendingOperation: @Sendable (Book) async -> Bool = { _ in false }
    var acceptanceOperation: @Sendable (BookServerAcceptance, BookReadingPermit, BookFileFingerprint) async -> Bool = { _, _, _ in true }
    var newAcceptanceOperation: @Sendable (BookServerAcceptance, AccountMutationPermit, BookFileFingerprint) async -> Bool = { _, _, _ in true }

    func currentUserId() async -> UserID? { await userIdProvider() }
    func ensureAccount(_ expectedUserId: UserID?) async throws {
        guard await accountIsActive() else { throw BookSyncAccountChanged() }
        if let expectedUserId, await userIdProvider() != expectedUserId { throw BookSyncAccountChanged() }
    }
    func captureAccountPermit(ownerID: UserID) async throws -> AccountMutationPermit? { try await capturePermitOperation(ownerID) }
    func ensureCommitAuthority(_ permit: AccountMutationPermit?, expectedUserId: UserID?) async throws {
        try Task.checkCancellation()
        try await ensureAccount(expectedUserId)
        try await validatePermitOperation(permit)
    }
    func prepareSourceReplacement(_ bookID: BookID, permit: AccountMutationPermit?) async throws -> BookSourceReplacementToken? { try await prepareReplacementOperation(bookID, permit) }
    func completeSourceReplacement(_ token: BookSourceReplacementToken) async throws { try await completeReplacementOperation(token) }
    func abortSourceReplacement(_ token: BookSourceReplacementToken) async { await abortReplacementOperation(token) }
    func materialize(_ book: Book, r2Key: String?, remoteFile: InboundBookFileMetadata?, permit: AccountMutationPermit?) async throws -> VerifiedDownloadedBook? { try await materializeOperation(book, r2Key, remoteFile, permit) }
    func admitCommit(_ permit: AccountMutationPermit?) async throws -> BookImportOperationLease? { try await admitCommitOperation(permit) }
    func persistFingerprint(_ fingerprint: BookFileFingerprint, for book: Book, generation: UInt64?) async -> Bool { await fingerprintOperation(fingerprint, book, generation) }
    func withDeletionAdmission(ownerID: UserID?, operation: @Sendable (UInt64?) async throws -> Void) async throws { try await deletionAdmissionOperation(ownerID, operation) }
    func retireBookForDeletion(_ bookID: BookID, ownerID: UserID?, generation: UInt64?) async throws -> BookDeletionRetirementWitness? { try await retirementOperation(bookID, ownerID, generation) }
    func prepareDeletionCleanup(_ bookID: BookID, ownerID: UserID?, existingBook: Book?) async throws -> (@Sendable () async throws -> Void)? { try await cleanupOperation(bookID, ownerID, existingBook) }
    func deferDeletionCleanup(_ witness: BookDeletionRetirementWitness, cleanup: @escaping @Sendable () async throws -> Void) { deferredCleanupOperation(witness, cleanup) }
    func restoreAfterFailedRetirement(_ book: Book, generation: UInt64?) async -> Bool { await restoreOperation(book, generation) }
    func scheduleRecovery(ownerID: UserID, generation: UInt64) async { await recoveryOperation(ownerID, generation) }
    func activateBook(_ bookID: BookID, permit: AccountMutationPermit?) async { await activationOperation(bookID, permit) }
    func managedFingerprint(_ book: Book) async -> BookFileFingerprint? { await managedFingerprintOperation(book) }
    func readingPermit(_ book: Book) async -> BookReadingPermit? { await readingPermitOperation(book) }
    func contentDigest(_ book: Book, fallbackFingerprint: BookFileFingerprint?) async -> String? { await digestOperation(book, fallbackFingerprint) }
    func hasPendingMaterialization(_ book: Book) async -> Bool { await pendingOperation(book) }
    func persistAcceptance(_ acceptance: BookServerAcceptance, permit: BookReadingPermit, fingerprint: BookFileFingerprint) async -> Bool { await acceptanceOperation(acceptance, permit, fingerprint) }
    func persistAcceptance(_ acceptance: BookServerAcceptance, permit: AccountMutationPermit, fingerprint: BookFileFingerprint) async -> Bool { await newAcceptanceOperation(acceptance, permit, fingerprint) }
}
