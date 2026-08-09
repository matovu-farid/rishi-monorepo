import Foundation


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

    func markCleanIfUnchanged(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool

    func markCleanIfCurrent(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        expectedOperationId: UUID,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool

    func acknowledgeTombstoneIfUnchanged(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool

    func acknowledgeTombstoneIfCurrent(
        entityId: UUID,
        kind: SyncEntityKind,
        expectedDirtyAt: Date?,
        expectedOperationId: UUID,
        lastSyncedAt: Date,
        remoteEtag: String?
    ) async throws -> Bool

    func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws
    func remoteSeenAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date?

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

    /// Erase the row. Used for ordinary metadata cleanup. Confirmed book
    /// tombstones are retained by `acknowledgeTombstoneIfUnchanged` so a
    /// later import cannot reuse the deleted identity.
    func forget(entityId: UUID, kind: SyncEntityKind) async throws

    /// Clears all account-scoped sync state during sign-out/account switch.
    func resetAll() async throws

    /// Records a durable deletion tombstone until the worker acknowledges it.
    func markTombstone(entityId: UUID, kind: SyncEntityKind) async throws

    /// Returns whether this identity has a deletion tombstone. Clean
    /// tombstones remain recorded after server acknowledgement.
    func isTombstone(entityId: UUID, kind: SyncEntityKind) async throws -> Bool

    /// Timestamp captured when the local mutation was marked dirty. This is
    /// the LWW timestamp sent to the Worker, rather than upload time.
    func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date?

    /// Stable identity for the currently pending local mutation. It must not
    /// change while a retry is in flight.
    func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID?
    func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID

    /// Last accepted remote timestamp for one entity, used when rebuilding
    /// the canonical local projection after a pull.
    func lastSyncedAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date?

    /// Returns durable progress for a cursor-driven sync plane.
    func cursorState(for scope: SyncCursorScope) async throws -> SyncCursorState?

    /// Promotes a successfully handled page cursor. This is separate from
    /// entity dirty-row acknowledgement and is called only by the page engine.
    func saveCursorState(_ state: SyncCursorState) async throws

    /// Clears one cursor plane without touching entity metadata.
    func clearCursorState(for scope: SyncCursorScope) async throws
    func clearCursorState(for scope: SyncCursorScope, accountGeneration: Int) async throws

    func recoveryState() async throws -> SyncRecoveryState?
    func saveRecoveryState(_ state: SyncRecoveryState) async throws
    func clearRecoveryState() async throws
    func clearRecoveryState(accountGeneration: Int) async throws
}

public enum SyncMetadataError: Error, Sendable, Equatable {
    case missingPendingOperation(entityId: UUID, kind: SyncEntityKind)
}

public extension SyncMetadataStore {
    func resetAll() async throws {}
    func markTombstone(entityId: UUID, kind: SyncEntityKind) async throws {
        try await markDirty(entityId: entityId, kind: kind)
    }
    func isTombstone(entityId: UUID, kind: SyncEntityKind) async throws -> Bool { false }
    func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { nil }
    func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? { nil }
    func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
        throw SyncMetadataError.missingPendingOperation(entityId: entityId, kind: kind)
    }
    func lastSyncedAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { nil }
    func markCleanIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        guard try await dirtyAt(entityId: entityId, kind: kind) == expectedDirtyAt else { return false }
        try await markClean(entityId: entityId, kind: kind, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
        return true
    }
    func markCleanIfCurrent(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, expectedOperationId: UUID, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        guard try await operationId(entityId: entityId, kind: kind) == expectedOperationId else { return false }
        return try await markCleanIfUnchanged(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
    }
    func acknowledgeTombstoneIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        guard try await markCleanIfUnchanged(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag) else { return false }
        return true
    }
    func acknowledgeTombstoneIfCurrent(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, expectedOperationId: UUID, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
        guard try await operationId(entityId: entityId, kind: kind) == expectedOperationId else { return false }
        return try await acknowledgeTombstoneIfUnchanged(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
    }
    func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {}
    func remoteSeenAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { nil }
    func cursorState(for scope: SyncCursorScope) async throws -> SyncCursorState? { nil }
    func saveCursorState(_ state: SyncCursorState) async throws {}
    func clearCursorState(for scope: SyncCursorScope) async throws {}
    func clearCursorState(for scope: SyncCursorScope, accountGeneration: Int) async throws {
        guard try await cursorState(for: scope)?.accountGeneration == accountGeneration else { return }
        try await clearCursorState(for: scope)
    }
    func recoveryState() async throws -> SyncRecoveryState? { nil }
    func saveRecoveryState(_ state: SyncRecoveryState) async throws {}
    func clearRecoveryState() async throws {}
    func clearRecoveryState(accountGeneration: Int) async throws {
        guard try await recoveryState()?.accountGeneration == accountGeneration else { return }
        try await clearRecoveryState()
    }
}

public struct SyncPendingItem: Sendable, Hashable {
    public let entityId: UUID
    public let kind: SyncEntityKind

    public init(entityId: UUID, kind: SyncEntityKind) {
        self.entityId = entityId
        self.kind = kind
    }
}
