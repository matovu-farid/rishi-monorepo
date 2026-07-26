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
}
