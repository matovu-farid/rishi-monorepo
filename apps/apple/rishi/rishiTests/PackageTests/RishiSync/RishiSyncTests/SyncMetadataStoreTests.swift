@testable import rishi
import Testing
import Foundation
import SwiftData
import Synchronization



@Suite("SyncMetadataStore — SwiftData round-trips", .serialized)
struct SyncMetadataStoreTests {

    private func makeStore() async throws -> SwiftDataSyncMetadataStore {
        try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
    }

    @Test("SyncEntityKind raw values are pinned to sync-v2 wire format")
    func entityKindRawValuesPinned() {
        // Keep the complete sync-v2 wire list, including chapter-index projection rows.
        let kinds = SyncEntityKind.allCases.map(\.rawValue).sorted()
        #expect(kinds == ["book", "bookmark", "chapter_index", "conversation", "highlight", "message", "position"])
    }

    @Test("Empty DB returns 0 pending + nil cursors")
    func emptyDBBaseline() async throws {
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
        let id = UUID()
        try await store.markDirty(entityId: id, kind: .book)
        let liveOperation = try #require(await store.operationId(entityId: id, kind: .book))
        try await store.markTombstone(entityId: id, kind: .book)

        let deleteOperation = try #require(await store.operationId(entityId: id, kind: .book))
        #expect(deleteOperation != liveOperation)
    }

    @Test("markClean clears dirty + writes cursor + remote etag")
    func markCleanClearsAndWritesCursor() async throws {
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = await SwiftDataSyncMetadataStore.make(container: container)

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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        // Ordinary clean cannot acknowledge or reopen a permanently deleted BookID.
        #expect(try await store.isTombstone(entityId: id, kind: .book))
        #expect(try await store.dirtyAt(entityId: id, kind: .book) != nil)
        #expect(try await store.pendingCount() == 1)
    }

    @Test("acknowledged book tombstones remain as clean barriers for re-import")
    func acknowledgedTombstoneRemainsRecorded() async throws {
        let store = try await makeStore()
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

    @Test("ordinary writers cannot erase pending or acknowledged native book tombstones", arguments: ["dirty", "clean", "conditionalClean", "operationClean", "forget"], [false, true])
    func ordinaryWritersPreserveBookTombstone(_ writer: String, _ acknowledged: Bool) async throws {
        let store = try await makeStore()
        let id = UUID()
        try await store.markTombstone(entityId: id, kind: .book)
        let operation = try #require(await store.operationId(entityId: id, kind: .book))
        let dirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .book))
        let acknowledgedAt = Date(timeIntervalSince1970: 1_700_000_020)
        if acknowledged {
            #expect(try await store.acknowledgeTombstoneIfCurrent(
                entityId: id, kind: .book, expectedDirtyAt: dirtyAt,
                expectedOperationId: operation, lastSyncedAt: acknowledgedAt, remoteEtag: "deleted"
            ))
        }
        let expectedDirtyAt = try await store.dirtyAt(entityId: id, kind: .book)
        let expectedOperation = try await store.operationId(entityId: id, kind: .book)
        let expectedCursor = try await store.lastSyncedAt(entityId: id, kind: .book)
        let later = acknowledgedAt.addingTimeInterval(100)
        switch writer {
        case "dirty": try await store.markDirty(entityId: id, kind: .book)
        case "clean": try await store.markClean(entityId: id, kind: .book, lastSyncedAt: later, remoteEtag: "live")
        case "conditionalClean":
            #expect(try await store.markCleanIfUnchanged(
                entityId: id, kind: .book, expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: later, remoteEtag: "live"
            ) == false)
        case "operationClean":
            #expect(try await store.markCleanIfCurrent(
                entityId: id, kind: .book, expectedDirtyAt: expectedDirtyAt,
                expectedOperationId: operation, lastSyncedAt: later, remoteEtag: "live"
            ) == false)
        default: try await store.forget(entityId: id, kind: .book)
        }
        #expect(try await store.isTombstone(entityId: id, kind: .book))
        #expect(try await store.dirtyAt(entityId: id, kind: .book) == expectedDirtyAt)
        #expect(try await store.operationId(entityId: id, kind: .book) == expectedOperation)
        #expect(try await store.lastSyncedAt(entityId: id, kind: .book) == expectedCursor)
        #expect(try await store.pendingCount() == (acknowledged ? 0 : 1))
        let mutations = SyncMetadataMutationCounter()
        await #expect(throws: SyncMetadataError.bookIdentityClosed(id)) {
            try await store.withLiveBookIdentity(id) { await mutations.increment() }
        }
        #expect(await mutations.count == 0)
    }

    @Test("legacy raw UUID book tombstones survive ordinary writers and forget")
    func legacyBookTombstoneStaysClosed() async throws {
        let container = try SyncMetadataStoreBootstrap.makeContainer(inMemory: true)
        let id = UUID()
        let operation = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_021)
        let context = ModelContext(container)
        context.insert(SyncMetadataRow(
            entityId: id.uuidString, entityType: SyncEntityKind.book.rawValue,
            dirtyAt: timestamp, operationId: operation, dirty: true, tombstone: true
        ))
        try context.save()
        let store = await SwiftDataSyncMetadataStore.make(container: container)
        try await store.markDirty(entityId: id, kind: .book)
        try await store.markClean(entityId: id, kind: .book, lastSyncedAt: Date(), remoteEtag: nil)
        try await store.forget(entityId: id, kind: .book)
        #expect(try await store.isTombstone(entityId: id, kind: .book))
        #expect(try await store.dirtyAt(entityId: id, kind: .book) == timestamp)
        #expect(try await store.operationId(entityId: id, kind: .book) == operation)
        #expect(try context.fetch(FetchDescriptor<SyncMetadataRow>()).count == 1)
    }

    @Test("highlight tombstones retain ordinary restore and forget semantics")
    func nonBookRestoreRemainsAvailable() async throws {
        let store = try await makeStore()
        let id = UUID()
        try await store.markTombstone(entityId: id, kind: .highlight)
        try await store.markDirty(entityId: id, kind: .highlight)
        #expect(try await store.isTombstone(entityId: id, kind: .highlight) == false)
        try await store.markTombstone(entityId: id, kind: .highlight)
        try await store.markClean(entityId: id, kind: .highlight, lastSyncedAt: Date(), remoteEtag: "restored")
        #expect(try await store.isTombstone(entityId: id, kind: .highlight) == false)
        try await store.markTombstone(entityId: id, kind: .highlight)
        let dirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .highlight))
        #expect(try await store.markCleanIfUnchanged(
            entityId: id, kind: .highlight, expectedDirtyAt: dirtyAt, lastSyncedAt: Date(), remoteEtag: nil
        ))
        #expect(try await store.isTombstone(entityId: id, kind: .highlight) == false)
        try await store.markTombstone(entityId: id, kind: .highlight)
        let nextDirtyAt = try #require(await store.dirtyAt(entityId: id, kind: .highlight))
        let operation = try #require(await store.operationId(entityId: id, kind: .highlight))
        #expect(try await store.markCleanIfCurrent(
            entityId: id, kind: .highlight, expectedDirtyAt: nextDirtyAt,
            expectedOperationId: operation, lastSyncedAt: Date(), remoteEtag: nil
        ))
        #expect(try await store.isTombstone(entityId: id, kind: .highlight) == false)
        try await store.markTombstone(entityId: id, kind: .highlight)
        try await store.forget(entityId: id, kind: .highlight)
        #expect(try await store.isTombstone(entityId: id, kind: .highlight) == false)
        #expect(try await store.pendingCount() == 0)
    }

    @Test("resetAll removes persisted cursors and dirty rows")
    func resetAllClearsAccountState() async throws {
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
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
        let store = try await makeStore()
        try await store.saveCursorState(.init(scope: .incremental, cursor: "incremental-1"))
        try await store.saveCursorState(.init(scope: .recovery, cursor: "recovery-1"))
        try await store.saveRecoveryState(.init(reason: .incompleteProjection))

        try await store.resetAll()

        #expect(try await store.cursorState(for: .incremental) == nil)
        #expect(try await store.cursorState(for: .recovery) == nil)
        #expect(try await store.recoveryState() == nil)
    }
    @Test("Rejected retirement preserves prior acceptance, including absent timestamp", arguments: [false, true])
    func rejectedPositionRetirementPreservesAcceptance(_ previouslyAccepted: Bool) async throws {
        let store = try await makeStore(); let bookID = UUID()
        let prior = previouslyAccepted ? Date(timeIntervalSince1970: 100) : nil
        if let prior { try await store.markClean(entityId: bookID, kind: .position, lastSyncedAt: prior, remoteEtag: nil) }
        try await store.markDirty(entityId: bookID, kind: .position)
        let dirty = try await store.dirtyAt(entityId: bookID, kind: .position)
        let operation = try await store.ensureOperationId(entityId: bookID, kind: .position)
        #expect(try await store.retireRejectedPosition(entityId: bookID, expectedDirtyAt: dirty, expectedOperationId: operation, previousLastSyncedAt: prior))
        #expect(try await store.pendingCount() == 0)
        #expect(try await store.lastSyncedAt(entityId: bookID, kind: .position) == prior)
    }

    @Test("Rejected retirement cannot erase a newer dirty operation")
    func rejectedPositionRetirementCAS() async throws {
        let store = try await makeStore(); let bookID = UUID()
        try await store.markDirty(entityId: bookID, kind: .position)
        let dirty = try await store.dirtyAt(entityId: bookID, kind: .position)
        let operation = try await store.ensureOperationId(entityId: bookID, kind: .position)
        try await store.markDirty(entityId: bookID, kind: .position)
        let newer = try await store.ensureOperationId(entityId: bookID, kind: .position)
        #expect(!(try await store.retireRejectedPosition(entityId: bookID, expectedDirtyAt: dirty, expectedOperationId: operation, previousLastSyncedAt: nil)))
        #expect(try await store.pendingCount() == 1)
        #expect(try await store.operationId(entityId: bookID, kind: .position) == newer)
    }

    @Test("Count and max preserve nullable timestamps, clean tombstones and malformed dirty IDs")
    @MainActor
    func countAndMaxPreserveStoredRowSemantics() async throws {
        let container = try SyncMetadataStoreBootstrap.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let datedBook = Date(timeIntervalSince1970: 100)
        let datedPosition = Date(timeIntervalSince1970: 200)
        let datedTombstone = Date(timeIntervalSince1970: 300)
        let datedUnknownKind = Date(timeIntervalSince1970: 400)
        let newerDirty = Date(timeIntervalSince1970: 900)
        let dirtyBookID = UUID()
        let rows = [
            SyncMetadataRow(entityId: "book:\(UUID())", entityType: "book"),
            SyncMetadataRow(entityId: "book:\(UUID())", entityType: "book", lastSyncedAt: datedBook),
            SyncMetadataRow(entityId: "book:\(UUID())", entityType: "book", lastSyncedAt: datedTombstone, tombstone: true),
            SyncMetadataRow(entityId: "book:\(dirtyBookID)", entityType: "book", lastSyncedAt: newerDirty, dirty: true),
            SyncMetadataRow(entityId: "position:\(UUID())", entityType: "position", lastSyncedAt: datedPosition),
            SyncMetadataRow(entityId: "position:malformed-id", entityType: "position", dirty: true),
            SyncMetadataRow(entityId: "legacy-kind:\(UUID())", entityType: "legacy-kind", lastSyncedAt: datedUnknownKind)
        ]
        for row in rows { context.insert(row) }
        try context.save()
        let store = await SwiftDataSyncMetadataStore.make(container: container)

        #expect(try await store.pendingCount() == 2)
        #expect(try await store.allDirty() == [.init(entityId: dirtyBookID, kind: .book)])
        #expect(try await store.lastSyncedAt(forKind: .book) == datedTombstone)
        #expect(try await store.lastSyncedAt(forKind: .position) == datedPosition)
        #expect(try await store.lastSyncedAt(forKind: .message) == nil)
        #expect(try await store.globalLastSyncedAt() == datedUnknownKind)
    }

    #if DEBUG
    @Test("A MainActor caller constructs the metadata context off its executor")
    @MainActor
    func mainActorFactoryCreatesContextOffMain() async throws {
        let creationObservations = Mutex<[Bool]>([])
        let store = try await SyncMetadataStoreBootstrap.makeStore(
            inMemory: true,
            onContextCreation: { isMainThread in
                creationObservations.withLock { $0.append(isMainThread) }
            }
        )
        #expect(creationObservations.withLock { $0 } == [false])
        try await store.markDirty(entityId: UUID(), kind: .position)
        #expect(try await store.pendingCount() == 1)
    }

    @Test("Failed mutation rollback cannot leak into the next successful save", arguments: [false, true])
    func failedMutationRollsBack(_ existingRow: Bool) async throws {
        let store = try await makeStore()
        let failedID = UUID()
        let acceptedAt = Date(timeIntervalSince1970: 123)
        if existingRow {
            try await store.markClean(entityId: failedID, kind: .position, lastSyncedAt: acceptedAt, remoteEtag: "accepted")
        }
        await store.failNextSaveForTesting(SyncMetadataSaveFailure.injected)
        await #expect(throws: SyncMetadataSaveFailure.injected) {
            try await store.markDirty(entityId: failedID, kind: .position)
        }
        #expect(try await store.pendingCount() == 0)
        #expect(try await store.dirtyAt(entityId: failedID, kind: .position) == nil)
        #expect(try await store.operationId(entityId: failedID, kind: .position) == nil)
        #expect(try await store.lastSyncedAt(entityId: failedID, kind: .position) == (existingRow ? acceptedAt : nil))

        let successfulID = UUID()
        try await store.markDirty(entityId: successfulID, kind: .position)
        #expect(try await store.pendingCount() == 1)
        #expect(try await store.allDirty() == [.init(entityId: successfulID, kind: .position)])
        #expect(try await store.lastSyncedAt(entityId: failedID, kind: .position) == (existingRow ? acceptedAt : nil))
    }
    #endif

    @Test("Atomic recovery preserves an import dirty mark admitted just before commit")
    func untrackedRecoveryPreservesConcurrentDirtyOperation() async throws {
        let store = try await makeStore(), id = UUID()
        let gate = UntrackedRecoveryCommitGate()
        let discovery = Task {
            try await store.withLiveBookIdentity(id) {
                #expect(try await store.dirtyAt(entityId: id, kind: .book) == nil)
                await gate.suspend()
                return try await store.markUntrackedBookDirtyIfAdmitted(id)
            }
        }
        await gate.waitForEntry()
        // Normal import marks do not take the identity gate. They must win the final atomic check.
        try await store.markDirty(entityId: id, kind: .book)
        let operation = try await store.operationId(entityId: id, kind: .book)
        let dirtyAt = try await store.dirtyAt(entityId: id, kind: .book)
        await gate.release()
        #expect(try await discovery.value == false)
        #expect(try await store.operationId(entityId: id, kind: .book) == operation)
        #expect(try await store.dirtyAt(entityId: id, kind: .book) == dirtyAt)
    }

    @Test("Atomic recovery only creates a never-synced live book operation", arguments: ["missing", "dirty", "synced", "deleted"])
    func atomicUntrackedBookAdmission(mode: String) async throws {
        let store = try await makeStore(), id = UUID()
        switch mode {
        case "dirty": try await store.markDirty(entityId: id, kind: .book)
        case "synced": try await store.markClean(entityId: id, kind: .book, lastSyncedAt: .distantPast, remoteEtag: nil)
        case "deleted": try await store.applyLocalBookTombstone(id, mutation: {})
        default: break
        }
        let operation = try await store.operationId(entityId: id, kind: .book)
        #expect(try await store.markUntrackedBookDirtyIfAdmitted(id) == (mode == "missing"))
        if mode == "missing" { #expect(try await store.operationId(entityId: id, kind: .book) != nil) }
        else { #expect(try await store.operationId(entityId: id, kind: .book) == operation) }
    }

}

private enum SyncMetadataSaveFailure: Error, Sendable, Equatable {
    case injected
}

private actor SyncMetadataMutationCounter {
    private(set) var count = 0
    func increment() { count += 1 }

}


private actor UntrackedRecoveryCommitGate {
    var entered = false
    var entryWaiters: [CheckedContinuation<Void, Never>] = []
    var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation {
            continuation = $0; entered = true
            entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
