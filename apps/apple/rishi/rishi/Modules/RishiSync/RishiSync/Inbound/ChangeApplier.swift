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
    private let bookMaterializer: (@Sendable (Book, String?) async throws -> Book)?
    private let bookMaterialCleanup: (@Sendable (Book) async throws -> Void)?
    private let bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)?

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        chapterIndexPersistence: (any ChapterIndexPersistence)? = nil,
        metadataStore: any SyncMetadataStore,
        currentUserId: @escaping @Sendable () async -> UserID? = { nil },
        accountIsActive: @escaping @Sendable () async -> Bool = { true },
        bookMaterializer: (@Sendable (Book, String?) async throws -> Book)? = nil,
        bookMaterialCleanup: (@Sendable (Book) async throws -> Void)? = nil,
        bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)? = nil
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
        self.bookMaterialCleanup = bookMaterialCleanup
        self.bookMaterialCleanupByID = bookMaterialCleanupByID
    }

    public func apply(_ changes: [SyncChange], expectedUserId: UserID? = nil) async -> ApplyResult {
        var result = ApplyResult()

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
                    try await applyHighlight(change, into: &result, expectedUserId: expectedUserId)
                case .book:
                    try await applyBook(change, into: &result, expectedUserId: expectedUserId)
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

    private func applyHighlight(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
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
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: change.id,
                kind: .highlight,
                expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: change.updatedAt,
                remoteEtag: nil
            ) else { throw ConditionalAcknowledgementFailed() }
            result.applied += 1
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
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .highlight,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
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

    private func applyBook(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .book)
        if change.deleted {
            // A server tombstone is authoritative for this closed identity.
            // If this device imported the same deterministic ID before it
            // learned about the remote delete, do not leave that stale live
            // row dirty forever; remove it and retain the local barrier.
            let expectedLocal = try await bookStore.book(change.id)
            try await ensureAccount(expectedUserId)
            guard try await bookStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
            // Clean only after the conditional row delete succeeds. If this
            // fails, the next retry still addresses material by ID even when
            // the row is already gone, and acknowledgement remains blocked.
            if let bookMaterialCleanupByID {
                try await bookMaterialCleanupByID(change.id)
            } else if let expectedLocal, let bookMaterialCleanup {
                try await bookMaterialCleanup(expectedLocal)
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
        let remote = try SyncPayloadCodec.decodeBook(
            change.payload,
            fallbackAddedAt: change.updatedAt,
            fallbackUserId: await currentUserId() ?? UUID()
        )
        let r2Key = try SyncPayloadCodec.decodeBookR2Key(change.payload)
        let materialized = if let bookMaterializer, r2Key != nil {
            try await bookMaterializer(remote, r2Key)
        } else {
            remote
        }
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
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.dirtyAt(entityId: entityId, kind: .book) == expectedDirtyAt else {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            throw ConditionalAcknowledgementFailed()
        }
        try await bookStore.upsert(materialized)
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
        // NOTE: File bytes pull-side is deferred to 07-04. The engine sees
        // the new book row and schedules a /api/sync/download-url + GET into
        // BookFileStorage on the next foreground sweep.
    }

    private func ensureAccount(_ expectedUserId: UserID?) async throws {
        guard await accountIsActive() else { throw AccountSwitched() }
        if let expectedUserId, await currentUserId() != expectedUserId {
            throw AccountSwitched()
        }
    }
}
