import Foundation




/// Applies inbound `[SyncChange]` to local stores with the SYNC-04 conflict
/// resolution policy.
///
/// Policy by kind:
///   - **Position metadata** — last-write-wins by `updatedAt`. Server-newer
///     overwrites only when *strictly* newer; ties favor local (server.updatedAt
///     equal to local means we already have it).
///   - **Highlights** — merge by ID. Different IDs are kept on both sides
///     (no conflict). Same ID with diverged content → latest `createdAt` wins.
///   - **Book metadata** — last-write-wins. Tombstone (`deleted=true`)
///     removes the row and local material, then retains a clean metadata
///     tombstone so the identity cannot be reused by a later import.
///   - **Conversation / Message** — accepted but no-op for now. Phase 9
///     will materialize the rows; we still `markClean` so the next push
///     doesn't echo back the just-applied cursor.
///
/// Every successful apply calls
/// `markClean(entityId: change.id, kind: ..., lastSyncedAt: change.updatedAt)`
/// so the inbound wave doesn't re-surface on the next outbound push.
public final class ChangeApplier: Sendable {

    private struct AccountSwitched: Error, CustomStringConvertible {
        var description: String { "account switched during inbound sync" }
    }

    private struct ConditionalAcknowledgementFailed: Error, CustomStringConvertible {
        var description: String { "conditional sync acknowledgement failed" }
    }

    private struct BookRetirementRecoveryRequired: Error, CustomStringConvertible {
        var description: String { "book remains listed after retirement but source recovery is required; remote tombstone remains unacknowledged" }
    }

    public struct ApplyResult: Sendable, Equatable {
        public var applied: Int = 0
        public var skipped: Int = 0
        public var conflicts: Int = 0  // local was newer → remote dropped
        public var errors: [String] = []
        public init() {}
    }

    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let highlightStore: any HighlightStore
    private let bookmarkStore: any BookmarkStore
    private let chapterIndexPersistence: (any ChapterIndexPersistence)?
    private let metadataStore: any SyncMetadataStore
    private let currentUserId: @Sendable () async -> UserID?
    private let accountIsActive: @Sendable () async -> Bool
    private let bookMaterializerWithAuthority: (@Sendable (Book, String?, InboundBookFileMetadata?, AccountMutationPermit) async throws -> VerifiedDownloadedBook)?
    private let isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)?
    private let admitAccountOperation: (@Sendable (AccountMutationPermit) async -> BookImportOperationLease?)?
    private let bookMaterializer: (@Sendable (Book, String?, InboundBookFileMetadata?) async throws -> VerifiedDownloadedBook)?
    private let bookFingerprintPersister: (@Sendable (Book, BookFileFingerprint, UInt64?) async -> Bool)?
    private let bookMaterialCleanup: (@Sendable (Book) async throws -> Void)?
    private let bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)?
    private let prepareBookMaterialCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))?
    private let withBookDeletionAdmission: (@Sendable (UserID, @Sendable (UInt64) async throws -> Void) async throws -> Void)?
    private let restoreBookAfterFailedRetirement: (@Sendable (Book, UInt64?) async -> Bool)?
    private let scheduleBookRecovery: (@Sendable (UserID, UInt64) async -> Void)?
    private let retireAndDrainBook: (@Sendable (BookID) async throws -> Void)?
    private let retireAndDrainBookForGeneration: (@Sendable (BookID, UserID, UInt64) async throws -> Void)?
    private let retireBookForDeletion: (@Sendable (BookID, AccountMutationPermit) async throws -> BookDeletionRetirementWitness)?
    private let deferBookDeletionCleanup: (@Sendable (BookDeletionRetirementWitness, @escaping @Sendable () async throws -> Void) -> Void)?
    private let prepareBookSourceReplacement: (@Sendable (BookID, AccountMutationPermit) async throws -> BookSourceReplacementToken)?
    private let completeBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async throws -> Void)?
    private let abortBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async -> Void)?
    private let activateBookWithAuthority: (@Sendable (BookID, AccountMutationPermit) async -> Void)?
    private let activateBook: (@Sendable (BookID) async -> Void)?
    private let managedFingerprintLookup: (@Sendable (Book) async -> BookFileFingerprint?)?
    private let bookReadingPermitLookup: (@Sendable (Book) async -> BookReadingPermit?)?
    private let bookAccountPermitLookup: (@Sendable () async -> AccountMutationPermit?)?
    private let bookContentDigestLookup: (@Sendable (Book) async -> String?)?
    private let hasPendingBookMaterialization: (@Sendable (Book) async -> Bool)?
    private let bookServerAcceptancePersister: (@Sendable (BookReadingPermit, BookFileFingerprint, BookServerAcceptance) async -> Bool)?
    private let newBookServerAcceptancePersister: (@Sendable (AccountMutationPermit, BookFileFingerprint, BookServerAcceptance) async -> Bool)?

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        chapterIndexPersistence: (any ChapterIndexPersistence)? = nil,
        metadataStore: any SyncMetadataStore,
        currentUserId: @escaping @Sendable () async -> UserID? = { nil },
        accountIsActive: @escaping @Sendable () async -> Bool = { true },
        bookMaterializerWithAuthority: (@Sendable (Book, String?, InboundBookFileMetadata?, AccountMutationPermit) async throws -> VerifiedDownloadedBook)? = nil,
        isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)? = nil,
        admitAccountOperation: (@Sendable (AccountMutationPermit) async -> BookImportOperationLease?)? = nil,
        prepareBookSourceReplacement: (@Sendable (BookID, AccountMutationPermit) async throws -> BookSourceReplacementToken)? = nil,
        completeBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async throws -> Void)? = nil,
        abortBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async -> Void)? = nil,
        bookMaterializer: (@Sendable (Book, String?, InboundBookFileMetadata?) async throws -> VerifiedDownloadedBook)? = nil,
        bookFingerprintPersister: (@Sendable (Book, BookFileFingerprint, UInt64?) async -> Bool)? = nil,
        bookMaterialCleanup: (@Sendable (Book) async throws -> Void)? = nil,
        bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)? = nil,
        prepareBookMaterialCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))? = nil,
        withBookDeletionAdmission: (@Sendable (UserID, @Sendable (UInt64) async throws -> Void) async throws -> Void)? = nil,
        restoreBookAfterFailedRetirement: (@Sendable (Book, UInt64?) async -> Bool)? = nil,
        scheduleBookRecovery: (@Sendable (UserID, UInt64) async -> Void)? = nil,
        retireAndDrainBook: (@Sendable (BookID) async throws -> Void)? = nil,
        retireAndDrainBookForGeneration: (@Sendable (BookID, UserID, UInt64) async throws -> Void)? = nil,
        retireBookForDeletion: (@Sendable (BookID, AccountMutationPermit) async throws -> BookDeletionRetirementWitness)? = nil,
        deferBookDeletionCleanup: (@Sendable (BookDeletionRetirementWitness, @escaping @Sendable () async throws -> Void) -> Void)? = nil,
        activateBook: (@Sendable (BookID) async -> Void)? = nil,
        activateBookWithAuthority: (@Sendable (BookID, AccountMutationPermit) async -> Void)? = nil,
        managedFingerprintLookup: (@Sendable (Book) async -> BookFileFingerprint?)? = nil,
        bookReadingPermitLookup: (@Sendable (Book) async -> BookReadingPermit?)? = nil,
        bookAccountPermitLookup: (@Sendable () async -> AccountMutationPermit?)? = nil,
        bookContentDigestLookup: (@Sendable (Book) async -> String?)? = nil,
        hasPendingBookMaterialization: (@Sendable (Book) async -> Bool)? = nil,
        bookServerAcceptancePersister: (@Sendable (BookReadingPermit, BookFileFingerprint, BookServerAcceptance) async -> Bool)? = nil,
        newBookServerAcceptancePersister: (@Sendable (AccountMutationPermit, BookFileFingerprint, BookServerAcceptance) async -> Bool)? = nil
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.chapterIndexPersistence = chapterIndexPersistence
        self.metadataStore = metadataStore
        self.currentUserId = currentUserId
        self.accountIsActive = accountIsActive
        self.bookMaterializerWithAuthority = bookMaterializerWithAuthority
        self.isCurrentAccountPermit = isCurrentAccountPermit
        self.admitAccountOperation = admitAccountOperation
        self.prepareBookSourceReplacement = prepareBookSourceReplacement
        self.completeBookSourceReplacement = completeBookSourceReplacement
        self.abortBookSourceReplacement = abortBookSourceReplacement
        self.bookMaterializer = bookMaterializer
        self.bookFingerprintPersister = bookFingerprintPersister
        self.bookMaterialCleanup = bookMaterialCleanup
        self.bookMaterialCleanupByID = bookMaterialCleanupByID
        self.prepareBookMaterialCleanup = prepareBookMaterialCleanup
        self.withBookDeletionAdmission = withBookDeletionAdmission
        self.restoreBookAfterFailedRetirement = restoreBookAfterFailedRetirement
        self.scheduleBookRecovery = scheduleBookRecovery
        self.retireAndDrainBook = retireAndDrainBook
        self.retireAndDrainBookForGeneration = retireAndDrainBookForGeneration
        self.retireBookForDeletion = retireBookForDeletion
        self.deferBookDeletionCleanup = deferBookDeletionCleanup
        self.activateBook = activateBook
        self.activateBookWithAuthority = activateBookWithAuthority
        self.managedFingerprintLookup = managedFingerprintLookup
        self.bookReadingPermitLookup = bookReadingPermitLookup
        self.bookAccountPermitLookup = bookAccountPermitLookup
        self.bookContentDigestLookup = bookContentDigestLookup
        self.hasPendingBookMaterialization = hasPendingBookMaterialization
        self.bookServerAcceptancePersister = bookServerAcceptancePersister
        self.newBookServerAcceptancePersister = newBookServerAcceptancePersister
    }

    public func apply(_ changes: [SyncChange], expectedUserId: UserID? = nil) async -> ApplyResult {
        var result = ApplyResult()
        var searchableDataApplied = false

        for change in changes {
            do { try await ensureAccount(expectedUserId) }
            catch {
                result.errors.append(String(describing: error))
                break
            }
            guard let kind = SyncEntityKind(rawValue: change.kind) else {
                result.errors.append("unknown kind \(change.kind)")
                continue
            }
            do {
                switch kind {
                case .position:
                    try await applyPosition(change, into: &result, expectedUserId: expectedUserId)
                case .highlight:
                    try await applyHighlight(
                        change,
                        into: &result,
                        searchableDataApplied: &searchableDataApplied,
                        expectedUserId: expectedUserId
                    )
                case .book:
                    try await applyBook(
                        change,
                        into: &result,
                        searchableDataApplied: &searchableDataApplied,
                        expectedUserId: expectedUserId
                    )
                case .bookmark:
                    try await applyBookmark(change, into: &result, expectedUserId: expectedUserId)
                case .chapterIndex:
                    try await applyChapterIndex(change, into: &result, expectedUserId: expectedUserId)
                case .conversation, .message:
                    // Phase 9 will wire — record the cursor so we don't echo.
                    result.skipped += 1
                    try await ensureAccount(expectedUserId)
                    let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: change.id, kind: kind)
                    if expectedDirtyAt != nil {
                        try await metadataStore.recordRemoteSeen(entityId: change.id, kind: kind, updatedAt: change.updatedAt)
                        result.conflicts += 1
                        continue
                    }
                    guard try await metadataStore.markCleanIfUnchanged(
                        entityId: change.id,
                        kind: kind,
                        expectedDirtyAt: expectedDirtyAt,
                        lastSyncedAt: change.updatedAt,
                        remoteEtag: nil
                    ) else { throw ConditionalAcknowledgementFailed() }
                }
            } catch {
                result.errors.append(String(describing: error))
                Log.error("sync.apply.failed", error: error)
                // Preserve the failed change as the cursor boundary. A later
                // successful change must not advance globalLastSyncedAt past it.
                break
            }
        }
        Log.event("sync.apply.completed", level: .info, data: [
            "applied": String(result.applied),
            "skipped": String(result.skipped),
            "conflicts": String(result.conflicts),
            "errors": String(result.errors.count),
        ])
        if searchableDataApplied {
            await MainActor.run {
                NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            }
        }
        return result
    }

    // MARK: - Per-kind appliers

    private func applyPosition(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let remote = try SyncPayloadCodec.decodePosition(change.payload, fallbackUpdatedAt: change.updatedAt)
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: remote.bookId, kind: .position)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: remote.bookId, kind: .position, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if let local = try await positionStore.position(for: remote.bookId),
           local.updatedAt >= remote.updatedAt {
            // Local is newer-or-equal → drop the remote change.
            try await metadataStore.recordRemoteSeen(entityId: remote.bookId, kind: .position, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await positionStore.upsert(remote)
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.bookId,
            kind: .position,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else {
            try await metadataStore.recordRemoteSeen(entityId: remote.bookId, kind: .position, updatedAt: change.updatedAt)
            throw ConditionalAcknowledgementFailed()
        }
        result.applied += 1
    }

    private func applyHighlight(
        _ change: SyncChange,
        into result: inout ApplyResult,
        searchableDataApplied: inout Bool,
        expectedUserId: UserID?
    ) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .highlight)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if change.deleted {
            let expectedLocal = try await highlightStore.highlight(change.id)
            if try await metadataStore.pending(kind: .highlight, limit: 10_000)
                .contains(where: { $0.entityId == change.id }) {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            }
            try await ensureAccount(expectedUserId)
            guard try await highlightStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
            searchableDataApplied = true
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: change.id,
                kind: .highlight,
                expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: change.updatedAt,
                remoteEtag: nil
            ) else { throw ConditionalAcknowledgementFailed() }
            result.applied += 1
            searchableDataApplied = true
            return
        }
        let remote = try SyncPayloadCodec.decodeHighlight(change.payload, fallbackCreatedAt: change.updatedAt)
        if let local = try await highlightStore.highlight(remote.id),
           local.createdAt >= remote.createdAt {
            // Same id, local newer → keep local.
            try await metadataStore.recordRemoteSeen(entityId: remote.id, kind: .highlight, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await highlightStore.upsert(remote)
        searchableDataApplied = true
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .highlight,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
        searchableDataApplied = true
    }

    private func applyBookmark(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .bookmark)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if change.deleted {
            let expectedLocal = try await bookmarkStore.bookmark(change.id)
            if try await metadataStore.pending(kind: .bookmark, limit: 10_000)
                .contains(where: { $0.entityId == change.id }) {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            }
            try await ensureAccount(expectedUserId)
            guard try await bookmarkStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: change.id,
                kind: .bookmark,
                expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: change.updatedAt,
                remoteEtag: nil
            ) else { throw ConditionalAcknowledgementFailed() }
            result.applied += 1
            return
        }
        let remote = try SyncPayloadCodec.decodeBookmark(change.payload, fallbackCreatedAt: change.updatedAt)
        if let local = try await bookmarkStore.bookmark(remote.id),
           local.createdAt >= remote.createdAt {
            // Same id, local newer-or-equal -> keep local (Pitfall 5: no echo).
            try await metadataStore.recordRemoteSeen(entityId: remote.id, kind: .bookmark, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await bookmarkStore.upsert(remote)
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .bookmark,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
    }

    private func applyChapterIndex(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .chapterIndex)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .chapterIndex, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        guard let chapterIndexPersistence else {
            result.skipped += 1
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.markCleanIfUnchanged(entityId: change.id, kind: .chapterIndex, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil) else { throw ConditionalAcknowledgementFailed() }
            return
        }
        let remote = try SyncPayloadCodec.decodeChapterIndex(change.payload, fallbackUpdatedAt: change.updatedAt)
        if let local = try await chapterIndexPersistence.chapterIndex(bookID: remote.bookID, contentVersion: remote.contentVersion), local.updatedAt >= remote.updatedAt {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .chapterIndex, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await chapterIndexPersistence.upsertChapterIndex(remote)
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(entityId: change.id, kind: .chapterIndex, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
    }

    private func applyBook(
        _ change: SyncChange,
        into result: inout ApplyResult,
        searchableDataApplied: inout Bool,
        expectedUserId: UserID?
    ) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .book)
        if change.deleted {
            // Resolve owner only to acquire admission; the canonical row is
            // re-read after admission before lifecycle retirement begins.
            let candidate = try await bookStore.book(change.id)
            let deletionOwner = candidate?.userId ?? expectedUserId
            if let deletionOwner, let withBookDeletionAdmission {
                try await withBookDeletionAdmission(deletionOwner) { generation in
                    try await self.applyBookTombstone(
                        change,
                        expectedDirtyAt: expectedDirtyAt,
                        expectedUserId: expectedUserId,
                        admittedOwnerID: deletionOwner,
                        admittedGeneration: generation
                    )
                }
            } else {
                try await applyBookTombstone(
                    change,
                    expectedDirtyAt: expectedDirtyAt,
                    expectedUserId: expectedUserId,
                    admittedOwnerID: deletionOwner,
                    admittedGeneration: nil
                )
            }
            searchableDataApplied = true
            result.applied += 1
            return
        }
        if try await metadataStore.isTombstone(entityId: entityId, kind: .book) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if try await metadataStore.pending(kind: .book, limit: 10_000).contains(where: { $0.entityId == change.id }) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let decoded = try SyncPayloadCodec.decodeBookPayload(
            change.payload,
            fallbackAddedAt: change.updatedAt,
            fallbackUserId: await currentUserId() ?? UUID()
        )
        let remote = decoded.book
        let embeddedPosition = try SyncPayloadCodec.decodeBookPosition(
            change.payload,
            bookId: remote.id,
            fallbackUpdatedAt: change.updatedAt
        )
        var embeddedPositionExpectedDirtyAt: Date?
        if let embeddedPosition {
            embeddedPositionExpectedDirtyAt = try await metadataStore.dirtyAt(
                entityId: embeddedPosition.bookId,
                kind: .position
            )
            if embeddedPositionExpectedDirtyAt != nil {
                try await metadataStore.recordRemoteSeen(
                    entityId: embeddedPosition.bookId,
                    kind: .position,
                    updatedAt: change.updatedAt
                )
                result.conflicts += 1
                return
            }
        }
        let r2Key = try SyncPayloadCodec.decodeBookR2Key(change.payload)
        let existingLocal = try await bookStore.book(change.id)
        let activeOwnerID = await currentUserId()
        if let existingLocal, existingLocal.userId != activeOwnerID {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let capturedAccountPermit = await bookAccountPermitLookup?()
        if bookAccountPermitLookup != nil {
            guard let capturedAccountPermit, capturedAccountPermit.ownerID == (existingLocal?.userId ?? remote.userId) else { throw AccountSwitched() }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        let existingFingerprint: BookFileFingerprint? = if let existingLocal, let managedFingerprintLookup {
            await managedFingerprintLookup(existingLocal)
        } else {
            nil
        }
        // Capture existing authority before download/materialization can await
        // external work. A newly restored row obtains its authority from the
        // verified commit path (Task 4), never from a post-response lookup.
        let existingReadingPermit: BookReadingPermit? = if let existingLocal, let bookReadingPermitLookup {
            await bookReadingPermitLookup(existingLocal)
        } else {
            nil
        }
        if let existingReadingPermit, let capturedAccountPermit {
            guard existingReadingPermit.ownerID == capturedAccountPermit.ownerID,
                  existingReadingPermit.accountGeneration == capturedAccountPermit.accountGeneration else { throw AccountSwitched() }
        }
        let newBookAccountPermit = existingLocal == nil ? capturedAccountPermit : nil
        let existingDigest: String? = if let existingLocal, let bookContentDigestLookup {
            await bookContentDigestLookup(existingLocal)
        } else {
            existingFingerprint?.sha256
        }
        if let expectedSHA = decoded.remoteFile.sha256,
           let existingDigest,
           expectedSHA.caseInsensitiveCompare(existingDigest) != .orderedSame {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        // Existing local bytes are never replaced by a metadata pull. For
        // source-readable imports, a missing fingerprint means the local
        // attempt still owns its canonical destination; only a later verified
        // download can establish managed readiness.
        let hasPendingImport = if let existingLocal, let hasPendingBookMaterialization {
            await hasPendingBookMaterialization(existingLocal)
        } else {
            false
        }
        let shouldDownload = existingLocal == nil || (existingFingerprint == nil && !hasPendingImport)
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if try await metadataStore.isTombstone(entityId: entityId, kind: .book) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let sourceReplacement: BookSourceReplacementToken?
        do {
            if shouldDownload, (bookMaterializer != nil || bookMaterializerWithAuthority != nil), r2Key != nil,
               let prepareBookSourceReplacement {
                guard let capturedAccountPermit else { throw AccountSwitched() }
                sourceReplacement = try await prepareBookSourceReplacement(change.id, capturedAccountPermit)
            } else { sourceReplacement = nil }
        } catch BookImportPromotionError.retired {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        do {
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let verifiedDownload: VerifiedDownloadedBook?
            do {
                if shouldDownload, r2Key != nil {
                    if let bookMaterializerWithAuthority {
                        guard let capturedAccountPermit else { throw AccountSwitched() }
                        verifiedDownload = try await bookMaterializerWithAuthority(remote, r2Key, decoded.remoteFile, capturedAccountPermit)
                    } else if let bookMaterializer {
                        verifiedDownload = try await bookMaterializer(remote, r2Key, decoded.remoteFile)
                    } else { verifiedDownload = nil }
                } else { verifiedDownload = nil }
            } catch SyncMetadataError.bookIdentityClosed {
                throw SyncMetadataError.bookIdentityClosed(entityId)
            }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let localPathPreservingPatch: Book = if let existingLocal {
                Book(
                    id: remote.id,
                    userId: existingLocal.userId,
                    title: remote.title,
                    author: remote.author,
                    formatType: existingLocal.formatType,
                    addedAt: existingLocal.addedAt,
                    openedAt: existingLocal.openedAt,
                    fileURL: existingLocal.fileURL,
                    coverPath: existingLocal.coverPath,
                    positionId: existingLocal.positionId,
                    conversationId: existingLocal.conversationId,
                    chapterIndexContentVersion: existingLocal.chapterIndexContentVersion
                )
            } else {
                remote
            }
            let materialized = verifiedDownload?.book ?? localPathPreservingPatch
            let operationLease: BookImportOperationLease?
            if let admitAccountOperation {
                guard let capturedAccountPermit, let admitted = await admitAccountOperation(capturedAccountPermit) else { throw AccountSwitched() }
                operationLease = admitted
            } else { operationLease = nil }
            defer { operationLease?.release() }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let positionDirtyAt = embeddedPositionExpectedDirtyAt
            let positionConflict: Bool
            do {
                positionConflict = try await metadataStore.withLiveBookIdentity(change.id) {
                    try await self.ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                    return try await self.commitLiveBook(
                        change: change, materialized: materialized, remote: remote,
                        remoteSHA256: decoded.remoteFile.sha256, verifiedDownload: verifiedDownload,
                        existingLocal: existingLocal, existingFingerprint: existingFingerprint,
                        existingReadingPermit: existingReadingPermit, newBookAccountPermit: newBookAccountPermit,
                        capturedAccountPermit: capturedAccountPermit, sourceReplacement: sourceReplacement, expectedUserId: expectedUserId, expectedDirtyAt: expectedDirtyAt,
                        embeddedPosition: embeddedPosition, embeddedPositionExpectedDirtyAt: positionDirtyAt
                    )
                }
            } catch SyncMetadataError.bookIdentityClosed {
                throw SyncMetadataError.bookIdentityClosed(entityId)
            }
            if positionConflict { result.conflicts += 1 }
            result.applied += 1
            searchableDataApplied = true
        } catch {
            if let sourceReplacement { await abortBookSourceReplacement?(sourceReplacement) }
            switch error {
            case SyncMetadataError.bookIdentityClosed, BookImportPromotionError.retired:
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            default: throw error
            }
        }
    }

    private func commitLiveBook(
        change: SyncChange, materialized: Book, remote: Book,
        remoteSHA256: String?, verifiedDownload: VerifiedDownloadedBook?,
        existingLocal: Book?, existingFingerprint: BookFileFingerprint?,
        existingReadingPermit: BookReadingPermit?, newBookAccountPermit: AccountMutationPermit?,
        capturedAccountPermit: AccountMutationPermit?, sourceReplacement: BookSourceReplacementToken?, expectedUserId: UserID?, expectedDirtyAt: Date?,
        embeddedPosition: Position?, embeddedPositionExpectedDirtyAt: Date?
    ) async throws -> Bool {
        let entityId = change.id
        var positionConflict = false
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        guard try await metadataStore.dirtyAt(entityId: entityId, kind: .book) == expectedDirtyAt else {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            throw ConditionalAcknowledgementFailed()
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        try await bookStore.upsert(materialized)
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if let verifiedDownload {
            let capturedGeneration = capturedAccountPermit?.accountGeneration ?? existingReadingPermit?.accountGeneration ?? newBookAccountPermit?.accountGeneration
            guard let bookFingerprintPersister,
                  await bookFingerprintPersister(materialized, verifiedDownload.fingerprint, capturedGeneration) else {
                throw ConditionalAcknowledgementFailed()
            }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            if let expectedHash = remoteSHA256,
               expectedHash.caseInsensitiveCompare(verifiedDownload.fingerprint.sha256) == .orderedSame,
               let operationID = change.operationId.flatMap(UUID.init(uuidString:)) {
                let acceptance = BookServerAcceptance(
                    sha256: verifiedDownload.fingerprint.sha256,
                    acceptedOperationID: operationID,
                    acceptedAt: change.updatedAt
                )
                if let existingReadingPermit, let bookServerAcceptancePersister {
                    guard await bookServerAcceptancePersister(existingReadingPermit, verifiedDownload.fingerprint, acceptance) else {
                        throw ConditionalAcknowledgementFailed()
                    }
                } else if existingLocal == nil,
                          let newBookAccountPermit,
                          let newBookServerAcceptancePersister {
                    guard await newBookServerAcceptancePersister(newBookAccountPermit, verifiedDownload.fingerprint, acceptance) else {
                        throw ConditionalAcknowledgementFailed()
                    }
                }
            }
        } else if let expectedHash = remoteSHA256,
                  let existingFingerprint,
                  expectedHash.caseInsensitiveCompare(existingFingerprint.sha256) == .orderedSame,
                  let operationID = change.operationId.flatMap(UUID.init(uuidString:)),
                  let existingReadingPermit,
                  let bookServerAcceptancePersister {
            let acceptance = BookServerAcceptance(
                sha256: existingFingerprint.sha256,
                acceptedOperationID: operationID,
                acceptedAt: change.updatedAt
            )
            guard await bookServerAcceptancePersister(existingReadingPermit, existingFingerprint, acceptance) else {
                throw ConditionalAcknowledgementFailed()
            }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if verifiedDownload != nil {
            if let sourceReplacement {
                guard let completeBookSourceReplacement else { throw BookImportPromotionError.retired }
                try await completeBookSourceReplacement(sourceReplacement)
            } else if let activateBookWithAuthority {
                guard let capturedAccountPermit else { throw AccountSwitched() }
                await activateBookWithAuthority(change.id, capturedAccountPermit)
            } else { await activateBook?(change.id) }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if let position = embeddedPosition {
            if let local = try await positionStore.position(for: position.bookId),
               local.updatedAt >= position.updatedAt {
                try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                positionConflict = true
            } else {
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                guard try await metadataStore.dirtyAt(entityId: position.bookId, kind: .position) == embeddedPositionExpectedDirtyAt else {
                    try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                    throw ConditionalAcknowledgementFailed()
                }
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                try await positionStore.upsert(position)
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                guard try await metadataStore.markCleanIfUnchanged(
                    entityId: position.bookId,
                    kind: .position,
                    expectedDirtyAt: embeddedPositionExpectedDirtyAt,
                    lastSyncedAt: change.updatedAt,
                    remoteEtag: nil
                ) else { throw ConditionalAcknowledgementFailed() }
            }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        return positionConflict
    }

    private func ensureCommitAuthority(_ permit: AccountMutationPermit?, expectedUserId: UserID?) async throws {
        try Task.checkCancellation()
        try await ensureAccount(expectedUserId)
        if let isCurrentAccountPermit {
            guard let permit, await isCurrentAccountPermit(permit) else { throw AccountSwitched() }
        }
    }

    private func applyBookTombstone(
        _ change: SyncChange,
        expectedDirtyAt: Date?,
        expectedUserId: UserID?,
        admittedOwnerID: UserID?,
        admittedGeneration: UInt64?
    ) async throws {
        try await ensureAccount(expectedUserId)
        // Hold the admitted owner operation before fencing/draining this
        // book. Account transition drains wait for the lease through cleanup
        // and tombstone acknowledgement.
        let retirement: BookDeletionRetirementWitness?
        if let admittedOwnerID, let admittedGeneration, let retireBookForDeletion, deferBookDeletionCleanup != nil {
            retirement = try await retireBookForDeletion(change.id, AccountMutationPermit(ownerID: admittedOwnerID, accountGeneration: admittedGeneration))
        } else if let admittedOwnerID, let admittedGeneration, let retireAndDrainBookForGeneration {
            try await retireAndDrainBookForGeneration(change.id, admittedOwnerID, admittedGeneration)
            retirement = nil
        } else {
            try await retireAndDrainBook?(change.id)
            retirement = nil
        }
        let expectedLocal: Book?
        do {
            expectedLocal = try await bookStore.book(change.id)
        } catch {
            _ = await restoreIfBookStillLive(change.id, generation: admittedGeneration)
            throw error
        }
        if let expectedLocal, expectedLocal.userId != admittedOwnerID {
            throw ConditionalAcknowledgementFailed()
        }
        if let expectedUserId, let admittedOwnerID, expectedUserId != admittedOwnerID {
            throw AccountSwitched()
        }
        try await ensureAccount(expectedUserId)

        // Capture the owner-bound attempt cleanup before the row disappears,
        // but defer all filesystem and pending-record deletion until the row
        // CAS succeeds. A retry can recapture by ID and admitted owner.
        let cleanupOwnerID = expectedLocal?.userId ?? admittedOwnerID
        let cleanupAction: (@Sendable () async throws -> Void)?
        do {
            if let prepareBookMaterialCleanup, let cleanupOwnerID {
                cleanupAction = try await prepareBookMaterialCleanup(change.id, cleanupOwnerID)
            } else {
                cleanupAction = nil
            }
            let acknowledged = try await metadataStore.applyBookTombstoneIfUnchanged(
                change.id, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil
            ) {
                let authority = admittedOwnerID.flatMap { owner in admittedGeneration.map { AccountMutationPermit(ownerID: owner, accountGeneration: $0) } }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
                let removed: Bool
                if retirement != nil, let authority {
                    removed = try await self.bookStore.deletePermanentlyIfUnchanged(change.id, matching: expectedLocal, accountPermit: authority)
                } else {
                    removed = try await self.bookStore.deleteIfUnchanged(change.id, matching: expectedLocal)
                }
                guard removed else {
                    try await self.metadataStore.recordRemoteSeen(entityId: change.id, kind: .book, updatedAt: change.updatedAt)
                    throw ConditionalAcknowledgementFailed()
                }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
                if retirement == nil {
                    if let cleanupAction { try await cleanupAction() }
                    else if let expectedLocal, let bookMaterialCleanup = self.bookMaterialCleanup { try await bookMaterialCleanup(expectedLocal) }
                    else if let bookMaterialCleanupByID = self.bookMaterialCleanupByID { try await bookMaterialCleanupByID(change.id) }
                }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
            }
            guard acknowledged else { throw ConditionalAcknowledgementFailed() }
            if let retirement, let deferBookDeletionCleanup, let cleanupAction {
                Log.event("sync.book.delete.logical_committed", data: ["book_id": change.id.uuidString])
                deferBookDeletionCleanup(retirement, cleanupAction)
            }
        } catch {
            if let _ = try? await bookStore.book(change.id),
               await restoreIfBookStillLive(change.id, generation: admittedGeneration) == false {
                throw BookRetirementRecoveryRequired()
            }
            throw error
        }
    }

    private func restoreIfBookStillLive(_ bookID: BookID, generation: UInt64?) async -> Bool? {
        let liveBook: Book
        do {
            guard let value = try await bookStore.book(bookID) else { return nil }
            liveBook = value
        } catch {
            return nil
        }
        if let restoreBookAfterFailedRetirement {
            let restored = await restoreBookAfterFailedRetirement(liveBook, generation)
            if !restored, let generation { await scheduleBookRecovery?(liveBook.userId, generation) }
            return restored
        } else {
            await activateBook?(bookID)
            let restored = activateBook != nil
            if !restored, let generation { await scheduleBookRecovery?(liveBook.userId, generation) }
            return restored
        }
    }

    private func ensureAccount(_ expectedUserId: UserID?) async throws {
        guard await accountIsActive() else { throw AccountSwitched() }
        if let expectedUserId, await currentUserId() != expectedUserId {
            throw AccountSwitched()
        }
    }
}
