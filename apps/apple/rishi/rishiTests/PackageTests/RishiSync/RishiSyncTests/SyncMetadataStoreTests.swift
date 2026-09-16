@testable import rishi
import Testing
import Foundation



@Suite("SyncMetadataStore — SwiftData round-trips", .serialized)
struct SyncMetadataStoreTests {

    private func makeStore() throws -> SwiftDataSyncMetadataStore {
        try SyncMetadataStoreBootstrap.makeStore(inMemory: true)
    }

    @Test("SyncEntityKind raw values are pinned to sync-v2 wire format")
    func entityKindRawValuesPinned() {
        // sync-v2 (Phase 37-08) adds the additive `bookmark` kind.
        let kinds = SyncEntityKind.allCases.map(\.rawValue).sorted()
        #expect(kinds == ["book", "bookmark", "conversation", "highlight", "message", "position"])
    }

    @Test("Empty DB returns 0 pending + nil cursors")
    func emptyDBBaseline() async throws {
        let store = try makeStore()
        let pendingCount = try await store.pendingCount()
        #expect(pendingCount == 0)
        let allDirty = try await store.allDirty()
        #expect(allDirty.isEmpty)
        let positionCursor = try await store.lastSyncedAt(forKind: .position)
        #expect(positionCursor == nil)
        let globalCursor = try await store.globalLastSyncedAt()
        #expect(globalCursor == nil)
    }

    @Test("markDirty inserts then sets dirty=1 idempotently")
    func markDirtyIsIdempotent() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .position)
        try await store.markDirty(entityId: id, kind: .position)
        let count = try await store.pendingCount()
        #expect(count == 1)
        let pending = try await store.allDirty()
        #expect(pending == [SyncPendingItem(entityId: id, kind: .position)])
    }

    @Test("each dirty mutation gets a new operation ID, while clean clears it")
    func dirtyOperationIdRotates() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let first = try #require(await store.operationId(entityId: id, kind: .book))

        try await store.markDirty(entityId: id, kind: .book)
        #expect(try await store.operationId(entityId: id, kind: .book) != first)

        try await store.markClean(
            entityId: id,
            kind: .book,
            lastSyncedAt: Date(),
            remoteEtag: nil
        )
        #expect(try await store.operationId(entityId: id, kind: .book) == nil)
    }

    @Test("missing or clean metadata cannot create an ephemeral operation ID")
    func operationIdRequiresPendingMetadata() async throws {
        let store = try makeStore()
        let id = UUID()
        await #expect(throws: SyncMetadataError.missingPendingOperation(entityId: id, kind: .book)) {
            try await store.ensureOperationId(entityId: id, kind: .book)
        }
        try await store.markClean(entityId: id, kind: .book, lastSyncedAt: Date(), remoteEtag: nil)
        await #expect(throws: SyncMetadataError.missingPendingOperation(entityId: id, kind: .book)) {
            try await store.ensureOperationId(entityId: id, kind: .book)
        }
    }

    @Test("a tombstone receives a new operation ID")
    func tombstoneOperationIdIsNew() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let liveOperation = try #require(await store.operationId(entityId: id, kind: .book))
        try await store.markTombstone(entityId: id, kind: .book)

        let deleteOperation = try #require(await store.operationId(entityId: id, kind: .book))
        #expect(deleteOperation != liveOperation)
    }

    @Test("markClean clears dirty + writes cursor + remote etag")
    func markCleanClearsAndWritesCursor() async throws {
        let store = try makeStore()
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.markDirty(entityId: id, kind: .highlight)
        let dirtyCount = try await store.pendingCount()
        #expect(dirtyCount == 1)

        try await store.markClean(entityId: id, kind: .highlight, lastSyncedAt: ts, remoteEtag: "etag-1")
        let cleanCount = try await store.pendingCount()
        #expect(cleanCount == 0)
        let cursor = try await store.lastSyncedAt(forKind: .highlight)
        #expect(cursor?.timeIntervalSince1970 == ts.timeIntervalSince1970)
        let globalCursor = try await store.globalLastSyncedAt()
        #expect(globalCursor?.timeIntervalSince1970 == ts.timeIntervalSince1970)
    }

    @Test("conditional clean preserves a newer local mutation")
    func conditionalCleanPreservesNewerLocalMutation() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let expectedDirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .book))

        try await Task.sleep(for: .milliseconds(1))
        try await store.markDirty(entityId: id, kind: .book)

        let acknowledged = try await store.markCleanIfUnchanged(
            entityId: id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_001),
            remoteEtag: nil
        )

        #expect(acknowledged == false)
        #expect(try await store.pendingCount() == 1)
    }

    @Test("operation-aware acknowledgement refuses an older upload")
    func operationAwareAcknowledgementRequiresMatchingOperation() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let dirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .book))
        let operation = try #require(await store.operationId(entityId: id, kind: .book))

        let rejected = try await store.markCleanIfCurrent(
            entityId: id,
            kind: .book,
            expectedDirtyAt: dirtyAt,
            expectedOperationId: UUID(),
            lastSyncedAt: Date(),
            remoteEtag: nil
        )
        #expect(!rejected)
        #expect(try await store.operationId(entityId: id, kind: .book) == operation)

        let acknowledged = try await store.markCleanIfCurrent(
            entityId: id,
            kind: .book,
            expectedDirtyAt: dirtyAt,
            expectedOperationId: operation,
            lastSyncedAt: Date(),
            remoteEtag: nil
        )
        #expect(acknowledged)
        #expect(try await store.pendingCount() == 0)
    }

    @Test("remote seen advances independently without clearing dirty state")
    func remoteSeenPreservesDirtyState() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .position)
        let remoteSeenAt = Date(timeIntervalSince1970: 1_700_000_002)

        try await store.recordRemoteSeen(entityId: id, kind: .position, updatedAt: remoteSeenAt)

        #expect(try await store.pendingCount() == 1)
        #expect(try await store.lastSyncedAt(entityId: id, kind: .position) == nil)
        #expect(try await store.remoteSeenAt(entityId: id, kind: .position) == remoteSeenAt)
    }

    @Test("legacy raw UUID metadata is reused without creating a kind-prefixed duplicate")
    func legacyRawUUIDMetadataIsReused() async throws {
        let container = try SyncMetadataStoreBootstrap.makeContainer(inMemory: true)
        let id = UUID()
        let expectedDirtyAt = Date(timeIntervalSince1970: 1_700_000_003)
        let context = ModelContext(container)
        context.insert(SyncMetadataRow(
            entityId: id.uuidString,
            entityType: SyncEntityKind.book.rawValue,
            dirtyAt: expectedDirtyAt,
            dirty: true
        ))
        try context.save()
        let store = SwiftDataSyncMetadataStore(container: container)

        let acknowledged = try await store.markCleanIfUnchanged(
            entityId: id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_004),
            remoteEtag: "legacy-etag"
        )

        #expect(acknowledged)
        #expect(try await store.pendingCount() == 0)
        let rows = try context.fetch(FetchDescriptor<SyncMetadataRow>())
        #expect(rows.count == 1)
        #expect(rows.first?.entityId == id.uuidString)
    }

    @Test("pending(forKind:limit:) filters by kind and caps")
    func pendingFiltersAndCaps() async throws {
        let store = try makeStore()
        for _ in 0..<5 { try await store.markDirty(entityId: UUID(), kind: .position) }
        for _ in 0..<3 { try await store.markDirty(entityId: UUID(), kind: .highlight) }

        let positions = try await store.pending(kind: .position, limit: 10)
        #expect(positions.count == 5)
        #expect(positions.allSatisfy { $0.kind == .position })

        let highlightsLimited = try await store.pending(kind: .highlight, limit: 2)
        #expect(highlightsLimited.count == 2)
        #expect(highlightsLimited.allSatisfy { $0.kind == .highlight })
    }

    @Test("forget removes the row")
    func forgetRemovesRow() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let beforeCount = try await store.pendingCount()
        #expect(beforeCount == 1)
        try await store.forget(entityId: id, kind: .book)
        let afterCount = try await store.pendingCount()
        #expect(afterCount == 0)
    }

    @Test("book and position dirtiness remain independent for one book")
    func bookAndPositionRowsAreIndependent() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        try await store.markDirty(entityId: id, kind: .position)

        #expect(try await store.pendingCount() == 2)
        #expect(try await store.pending(kind: .book, limit: 10).count == 1)
        #expect(try await store.pending(kind: .position, limit: 10).count == 1)

        try await store.markClean(
            entityId: id,
            kind: .book,
            lastSyncedAt: Date(),
            remoteEtag: nil
        )
        #expect(try await store.pending(kind: .position, limit: 10).count == 1)
    }

    @Test("dirty timestamps and tombstones survive without a local entity row")
    func dirtyTimestampAndTombstone() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markTombstone(entityId: id, kind: .book)

        #expect(try await store.isTombstone(entityId: id, kind: .book))
        #expect(try await store.dirtyAt(entityId: id, kind: .book) != nil)
        #expect(try await store.allDirty() == [SyncPendingItem(entityId: id, kind: .book)])

        try await store.markClean(
            entityId: id,
            kind: .book,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            remoteEtag: nil
        )
        #expect(try await store.isTombstone(entityId: id, kind: .book) == false)
        #expect(try await store.dirtyAt(entityId: id, kind: .book) == nil)
    }

    @Test("acknowledged book tombstones remain as clean barriers for re-import")
    func acknowledgedTombstoneRemainsRecorded() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.markTombstone(entityId: id, kind: .book)
        let expectedDirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .book))

        let acknowledged = try await store.acknowledgeTombstoneIfUnchanged(
            entityId: id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_010),
            remoteEtag: nil
        )

        #expect(acknowledged)
        #expect(try await store.pendingCount() == 0)
        #expect(try await store.dirtyAt(entityId: id, kind: .book) == nil)
        #expect(try await store.isTombstone(entityId: id, kind: .book))
    }

    @Test("resetAll removes persisted cursors and dirty rows")
    func resetAllClearsAccountState() async throws {
        let store = try makeStore()
        try await store.markDirty(entityId: UUID(), kind: .book)
        try await store.markClean(
            entityId: UUID(),
            kind: .highlight,
            lastSyncedAt: Date(),
            remoteEtag: nil
        )
        try await store.resetAll()

        #expect(try await store.pendingCount() == 0)
        #expect(try await store.globalLastSyncedAt() == nil)
    }

    @Test("incremental and recovery cursor states persist independently")
    func cursorStatesPersistIndependently() async throws {
        let store = try makeStore()
        try await store.saveCursorState(.init(scope: .incremental, cursor: "incremental-1"))
        try await store.saveCursorState(.init(scope: .recovery, cursor: "recovery-1"))

        #expect(try await store.cursorState(for: .incremental)?.cursor == "incremental-1")
        #expect(try await store.cursorState(for: .recovery)?.cursor == "recovery-1")

        try await store.saveCursorState(.init(scope: .incremental, cursor: "incremental-2"))
        #expect(try await store.cursorState(for: .incremental)?.cursor == "incremental-2")
        #expect(try await store.cursorState(for: .recovery)?.cursor == "recovery-1")
    }

    @Test("recovery reason persists independently from cursor progress")
    func recoveryReasonPersistsIndependently() async throws {
        let store = try makeStore()
        try await store.saveRecoveryState(.init(
            reason: .incompleteProjection,
            accountGeneration: 7
        ))
        try await store.saveCursorState(.init(
            scope: .recovery,
            cursor: "recovery-1",
            accountGeneration: 7
        ))

        #expect(try await store.recoveryState() == .init(
            reason: .incompleteProjection,
            accountGeneration: 7
        ))
        #expect(try await store.cursorState(for: .recovery)?.cursor == "recovery-1")

        try await store.clearRecoveryState()
        #expect(try await store.recoveryState() == nil)
        #expect(try await store.cursorState(for: .recovery)?.cursor == "recovery-1")
    }

    @Test("resetAll clears both durable cursor states")
    func resetAllClearsCursorStates() async throws {
        let store = try makeStore()
        try await store.saveCursorState(.init(scope: .incremental, cursor: "incremental-1"))
        try await store.saveCursorState(.init(scope: .recovery, cursor: "recovery-1"))
        try await store.saveRecoveryState(.init(reason: .incompleteProjection))

        try await store.resetAll()

        #expect(try await store.cursorState(for: .incremental) == nil)
        #expect(try await store.cursorState(for: .recovery) == nil)
        #expect(try await store.recoveryState() == nil)
    }
}
