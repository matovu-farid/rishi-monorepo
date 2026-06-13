import Foundation
import RishiAPI
import RishiCore
import RishiLogging

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
///     cascades through `BookStore.delete` + `SyncMetadataStore.forget`.
///     File-bytes pull-side is deferred to 07-04 (engine sees the new row
///     and schedules a `/api/sync/download-url` + GET into `BookFileStorage`).
///   - **Conversation / Message** — accepted but no-op for now. Phase 9
///     will materialize the rows; we still `markClean` so the next push
///     doesn't echo back the just-applied cursor.
///
/// Every successful apply calls
/// `markClean(entityId: change.id, kind: ..., lastSyncedAt: change.updatedAt)`
/// so the inbound wave doesn't re-surface on the next outbound push.
public final class ChangeApplier: Sendable {

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
    private let metadataStore: any SyncMetadataStore

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.metadataStore = metadataStore
    }

    public func apply(_ changes: [SyncChange]) async -> ApplyResult {
        var result = ApplyResult()

        for change in changes {
            guard let kind = SyncEntityKind(rawValue: change.kind) else {
                result.errors.append("unknown kind \(change.kind)")
                continue
            }
            do {
                switch kind {
                case .position:
                    try await applyPosition(change, into: &result)
                case .highlight:
                    try await applyHighlight(change, into: &result)
                case .book:
                    try await applyBook(change, into: &result)
                case .conversation, .message:
                    // Phase 9 will wire — record the cursor so we don't echo.
                    result.skipped += 1
                    try await metadataStore.markClean(
                        entityId: change.id,
                        kind: kind,
                        lastSyncedAt: change.updatedAt,
                        remoteEtag: nil
                    )
                }
            } catch {
                result.errors.append(String(describing: error))
                Log.error("sync.apply.failed", error: error)
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

    private func applyPosition(_ change: SyncChange, into result: inout ApplyResult) async throws {
        let remote = try SyncPayloadCodec.decodePosition(change.payload, fallbackUpdatedAt: change.updatedAt)
        if let local = try await positionStore.position(for: remote.bookId),
           local.updatedAt >= remote.updatedAt {
            // Local is newer-or-equal → drop the remote change.
            result.conflicts += 1
            return
        }
        try await positionStore.upsert(remote)
        try await metadataStore.markClean(
            entityId: remote.bookId,
            kind: .position,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        )
        result.applied += 1
    }

    private func applyHighlight(_ change: SyncChange, into result: inout ApplyResult) async throws {
        if change.deleted {
            try await highlightStore.delete(change.id)
            try await metadataStore.forget(entityId: change.id, kind: .highlight)
            result.applied += 1
            return
        }
        let remote = try SyncPayloadCodec.decodeHighlight(change.payload, fallbackCreatedAt: change.updatedAt)
        if let local = try await highlightStore.highlight(remote.id),
           local.createdAt >= remote.createdAt {
            // Same id, local newer → keep local.
            result.conflicts += 1
            return
        }
        try await highlightStore.upsert(remote)
        try await metadataStore.markClean(
            entityId: remote.id,
            kind: .highlight,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        )
        result.applied += 1
    }

    private func applyBook(_ change: SyncChange, into result: inout ApplyResult) async throws {
        if change.deleted {
            try await bookStore.delete(change.id)
            try await metadataStore.forget(entityId: change.id, kind: .book)
            result.applied += 1
            return
        }
        let remote = try SyncPayloadCodec.decodeBook(change.payload, fallbackAddedAt: change.updatedAt)
        try await bookStore.upsert(remote)
        try await metadataStore.markClean(
            entityId: remote.id,
            kind: .book,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        )
        result.applied += 1
        // NOTE: File bytes pull-side is deferred to 07-04. The engine sees
        // the new book row and schedules a /api/sync/download-url + GET into
        // BookFileStorage on the next foreground sweep.
    }
}
