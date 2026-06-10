import Foundation
import RishiCore

/// Read/write surface over the v1 `sync_metadata` table.
///
/// Schema (already shipped in Phase 2 v1_initial migration):
///   - `entity_id`      TEXT PK NOT NULL
///   - `entity_type`    TEXT NOT NULL          (SyncEntityKind raw value)
///   - `remote_etag`    TEXT
///   - `last_synced_at` REAL                   (seconds since epoch)
///   - `dirty`          INTEGER NOT NULL DEFAULT 0   (0/1)
///
/// Outbound uploaders (07-03) call `markDirty` from the Position/Highlight
/// write paths; on successful POST they call `markClean` with the server's
/// accepted-at cursor. `ChangeApplier` (07-03) calls `markClean` immediately
/// after applying a server-side change so we don't echo it back on push.
public protocol SyncMetadataStore: Sendable {
    /// Idempotent. Inserts the row if missing.
    func markDirty(entityId: UUID, kind: SyncEntityKind) async throws

    /// Sets dirty=0 + last_synced_at + remote_etag. Inserts if missing.
    func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws

    /// All rows with `dirty=1`, ordered by `entity_id ASC` for determinism.
    func allDirty() async throws -> [SyncPendingItem]

    /// Subset filtered by kind, capped at `limit`, ordered by `entity_id ASC`.
    func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem]

    /// Total count of `dirty=1` rows across all kinds.
    func pendingCount() async throws -> Int

    /// `MAX(last_synced_at) WHERE entity_type=? AND dirty=0`. Nil if no rows.
    func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date?

    /// `MAX(last_synced_at)` across every kind where `dirty=0`. Used as the
    /// global cursor passed into `/api/sync/changes?since=`.
    func globalLastSyncedAt() async throws -> Date?

    /// Erase the row. Called after the server confirms a tombstone delete.
    func forget(entityId: UUID, kind: SyncEntityKind) async throws
}

public struct SyncPendingItem: Sendable, Hashable {
    public let entityId: UUID
    public let kind: SyncEntityKind

    public init(entityId: UUID, kind: SyncEntityKind) {
        self.entityId = entityId
        self.kind = kind
    }
}
