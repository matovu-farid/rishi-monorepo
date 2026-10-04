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
    private let bookMaterializer: (@Sendable (Book, String?, InboundBookFileMetadata?) async throws -> VerifiedDownloadedBook)?
    private let bookFingerprintPersister: (@Sendable (Book, BookFileFingerprint) async -> Bool)?
    private let bookMaterialCleanup: (@Sendable (Book) async throws -> Void)?
    private let bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)?
    private let prepareBookMaterialCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))?
    private let withBookDeletionAdmission: (@Sendable (UserID, @Sendable (UInt64) async throws -> Void) async throws -> Void)?
    private let restoreBookAfterFailedRetirement: (@Sendable (Book, UInt64?) async -> Bool)?
    private let scheduleBookRecovery: (@Sendable (UserID, UInt64) async -> Void)?
    private let retireAndDrainBook: (@Sendable (BookID) async throws -> Void)?
    private let retireAndDrainBookForGeneration: (@Sendable (BookID, UserID, UInt64) async throws -> Void)?
    private let activateBook: (@Sendable (BookID) async -> Void)?
    private let managedFingerprintLookup: (@Sendable (Book) async -> BookFileFingerprint?)?
    private let bookContentDigestLookup: (@Sendable (Book) async -> String?)?
    private let hasPendingBookMaterialization: (@Sendable (Book) async -> Bool)?
    private let bookServerAcceptancePersister: (@Sendable (Book, BookFileFingerprint, BookServerAcceptance) async -> Bool)?

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        chapterIndexPersistence: (any ChapterIndexPersistence)? = nil,
        metadataStore: any SyncMetadataStore,
        currentUserId: @escaping @Sendable () async -> UserID? = { nil },
        accountIsActive: @escaping @Sendable () async -> Bool = { true },
        bookMaterializer: (@Sendable (Book, String?, InboundBookFileMetadata?) async throws -> VerifiedDownloadedBook)? = nil,
        bookFingerprintPersister: (@Sendable (Book, BookFileFingerprint) async -> Bool)? = nil,
        bookMaterialCleanup: (@Sendable (Book) async throws -> Void)? = nil,
        bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)? = nil,
        prepareBookMaterialCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))? = nil,
        withBookDeletionAdmission: (@Sendable (UserID, @Sendable (UInt64) async throws -> Void) async throws -> Void)? = nil,
        restoreBookAfterFailedRetirement: (@Sendable (Book, UInt64?) async -> Bool)? = nil,
        scheduleBookRecovery: (@Sendable (UserID, UInt64) async -> Void)? = nil,
        retireAndDrainBook: (@Sendable (BookID) async throws -> Void)? = nil,
        retireAndDrainBookForGeneration: (@Sendable (BookID, UserID, UInt64) async throws -> Void)? = nil,
        activateBook: (@Sendable (BookID) async -> Void)? = nil,
        managedFingerprintLookup: (@Sendable (Book) async -> BookFileFingerprint?)? = nil,
        bookContentDigestLookup: (@Sendable (Book) async -> String?)? = nil,
        hasPendingBookMaterialization: (@Sendable (Book) async -> Bool)? = nil,
        bookServerAcceptancePersister: (@Sendable (Book, BookFileFingerprint, BookServerAcceptance) async -> Bool)? = nil
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.chapterIndexPersistence = chapterIndexPersistence
        self.metadataStore = metadataStore
        self.currentUserId = currentUserId
        self.accountIsActive = accountIsActive
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
        self.activateBook = activateBook
        self.managedFingerprintLookup = managedFingerprintLookup
        self.bookContentDigestLookup = bookContentDigestLookup
        self.hasPendingBookMaterialization = hasPendingBookMaterialization
        self.bookServerAcceptancePersister = bookServerAcceptancePersister
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
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
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
        let existingFingerprint: BookFileFingerprint? = if let existingLocal, let managedFingerprintLookup {
            await managedFingerprintLookup(existingLocal)
        } else {
            nil
        }
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
        if shouldDownload, bookMaterializer != nil, r2Key != nil {
            try await retireAndDrainBook?(change.id)
        }
        let verifiedDownload: VerifiedDownloadedBook? = if shouldDownload, let bookMaterializer, r2Key != nil {
            try await bookMaterializer(remote, r2Key, decoded.remoteFile)
        } else {
            nil
        }
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
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.dirtyAt(entityId: entityId, kind: .book) == expectedDirtyAt else {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            throw ConditionalAcknowledgementFailed()
        }
        try await bookStore.upsert(materialized)
        if let verifiedDownload {
            guard let bookFingerprintPersister,
                  await bookFingerprintPersister(materialized, verifiedDownload.fingerprint) else {
                throw ConditionalAcknowledgementFailed()
            }
            if let expectedHash = decoded.remoteFile.sha256,
               expectedHash.caseInsensitiveCompare(verifiedDownload.fingerprint.sha256) == .orderedSame,
               let operationID = change.operationId.flatMap(UUID.init(uuidString:)),
               let bookServerAcceptancePersister {
                let acceptance = BookServerAcceptance(
                    sha256: verifiedDownload.fingerprint.sha256,
                    acceptedOperationID: operationID,
                    acceptedAt: change.updatedAt
                )
                _ = await bookServerAcceptancePersister(materialized, verifiedDownload.fingerprint, acceptance)
            }
        } else if let expectedHash = decoded.remoteFile.sha256,
                  let existingFingerprint,
                  expectedHash.caseInsensitiveCompare(existingFingerprint.sha256) == .orderedSame,
                  let operationID = change.operationId.flatMap(UUID.init(uuidString:)),
                  let bookServerAcceptancePersister {
            let acceptance = BookServerAcceptance(
                sha256: existingFingerprint.sha256,
                acceptedOperationID: operationID,
                acceptedAt: change.updatedAt
            )
            _ = await bookServerAcceptancePersister(materialized, existingFingerprint, acceptance)
        }
        if verifiedDownload != nil, let activateBook {
            await activateBook(change.id)
        }
        searchableDataApplied = true
        if let position = embeddedPosition {
            if let local = try await positionStore.position(for: position.bookId),
               local.updatedAt >= position.updatedAt {
                try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                result.conflicts += 1
            } else {
                try await ensureAccount(expectedUserId)
                guard try await metadataStore.dirtyAt(entityId: position.bookId, kind: .position) == embeddedPositionExpectedDirtyAt else {
                    try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                    throw ConditionalAcknowledgementFailed()
                }
                try await positionStore.upsert(position)
                try await ensureAccount(expectedUserId)
                guard try await metadataStore.markCleanIfUnchanged(
                    entityId: position.bookId,
                    kind: .position,
                    expectedDirtyAt: embeddedPositionExpectedDirtyAt,
                    lastSyncedAt: change.updatedAt,
                    remoteEtag: nil
                ) else { throw ConditionalAcknowledgementFailed() }
            }
        }
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
        searchableDataApplied = true
        // NOTE: File bytes pull-side is deferred to 07-04. The engine sees
        // the new book row and schedules a /api/sync/download-url + GET into
        // BookFileStorage on the next foreground sweep.
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
        if let admittedOwnerID, let admittedGeneration, let retireAndDrainBookForGeneration {
            try await retireAndDrainBookForGeneration(change.id, admittedOwnerID, admittedGeneration)
        } else {
            try await retireAndDrainBook?(change.id)
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
            try await ensureAccount(expectedUserId)
            guard try await bookStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await ensureAccount(expectedUserId)
                try await metadataStore.recordRemoteSeen(entityId: change.id, kind: .book, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
        } catch {
            // If CAS did not remove the row, restore through the coordinator,
            // which rechecks the canonical row and tombstone before reopening.
            if let _ = try? await bookStore.book(change.id),
               await restoreIfBookStillLive(change.id, generation: admittedGeneration) == false {
                throw BookRetirementRecoveryRequired()
            }
            throw error
        }

        if let cleanupAction {
            try await cleanupAction()
        } else if let expectedLocal, let bookMaterialCleanup {
            try await bookMaterialCleanup(expectedLocal)
        } else if let bookMaterialCleanupByID {
            try await bookMaterialCleanupByID(change.id)
        }
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
            entityId: change.id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else {
            throw ConditionalAcknowledgementFailed()
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
