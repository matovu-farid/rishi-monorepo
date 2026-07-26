@testable import rishi
import Testing
import Foundation



@Suite("SyncQueue — FIFO over a SyncMetadataStore stub")
struct SyncQueueTests {

    /// Minimal in-memory `SyncMetadataStore` stub for queue tests. The real
    /// SwiftData-backed implementation is covered by `SyncMetadataStoreTests`.
    private actor StubMetadataStore: SyncMetadataStore {
        private var dirty: [SyncPendingItem] = []

        func seed(_ items: [SyncPendingItem]) { dirty = items }

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
            if !dirty.contains(where: { $0.entityId == entityId && $0.kind == kind }) {
                dirty.append(SyncPendingItem(entityId: entityId, kind: kind))
            }
        }
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            dirty.removeAll { $0.entityId == entityId && $0.kind == kind }
        }
        func allDirty() async throws -> [SyncPendingItem] {
            dirty.sorted { $0.entityId.uuidString < $1.entityId.uuidString }
        }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] {
            Array(dirty.filter { $0.kind == kind }.prefix(limit))
        }
        func pendingCount() async throws -> Int { dirty.count }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            dirty.removeAll { $0.entityId == entityId && $0.kind == kind }
        }
    }

    @Test("refreshFromStore hydrates from dirty rows")
    func refreshFromStoreHydrates() async throws {
        let stub = StubMetadataStore()
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        await stub.seed([
            SyncPendingItem(entityId: a, kind: .position),
            SyncPendingItem(entityId: b, kind: .highlight),
        ])
        let queue = SyncQueue(metadataStore: stub)
        try await queue.refreshFromStore()
        let count = await queue.pendingCount()
        #expect(count == 2)
        let head = await queue.peek()
        #expect(head?.entityId == a)
    }

    @Test("enqueue + dequeue preserve FIFO order")
    func fifoPreserved() async throws {
        let stub = StubMetadataStore()
        let queue = SyncQueue(metadataStore: stub)
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            await queue.enqueue(SyncQueueItem(entityId: id, kind: .position))
        }
        let drained = await queue.dequeueNext(limit: 10)
        #expect(drained.map(\.entityId) == ids)
        let remaining = await queue.pendingCount()
        #expect(remaining == 0)
    }

    @Test("dequeueNext respects limit + leaves tail")
    func dequeueRespectsLimit() async throws {
        let stub = StubMetadataStore()
        let queue = SyncQueue(metadataStore: stub)
        for _ in 0..<5 {
            await queue.enqueue(SyncQueueItem(entityId: UUID(), kind: .highlight))
        }
        let first = await queue.dequeueNext(limit: 2)
        #expect(first.count == 2)
        let remaining = await queue.pendingCount()
        #expect(remaining == 3)
    }

    @Test("enqueue de-dupes by (entityId, kind)")
    func enqueueDeDupes() async throws {
        let stub = StubMetadataStore()
        let queue = SyncQueue(metadataStore: stub)
        let id = UUID()
        await queue.enqueue(SyncQueueItem(entityId: id, kind: .position))
        await queue.enqueue(SyncQueueItem(entityId: id, kind: .position))
        let count = await queue.pendingCount()
        #expect(count == 1)
    }
}
