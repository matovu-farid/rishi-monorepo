import Foundation


/// In-memory FIFO queue of pending sync work, backed by `SyncMetadataStore`.
///
/// `SyncEngine` (07-04) calls `refreshFromStore()` at the top of every sync
/// run to hydrate from `sync_metadata WHERE dirty=1`. Outbound uploaders pop
/// items via `dequeueNext(limit:)`. New writes during a sync run get
/// `enqueue()`'d directly so a flush at engine teardown picks them up.
public actor SyncQueue {

    private let metadataStore: any SyncMetadataStore
    private var items: [SyncQueueItem] = []
    private var loaded = false

    public init(metadataStore: any SyncMetadataStore) {
        self.metadataStore = metadataStore
    }

    /// Drains the store's dirty rows into the FIFO. Items already in the
    /// queue are preserved at the head (de-duped by `entityId + kind`).
    public func refreshFromStore() async throws {
        let dirty = try await metadataStore.allDirty()
        var seen = Set(items.map { Pair(entityId: $0.entityId, kind: $0.kind) })
        for pending in dirty {
            let pair = Pair(entityId: pending.entityId, kind: pending.kind)
            if seen.insert(pair).inserted {
                items.append(SyncQueueItem(entityId: pending.entityId, kind: pending.kind))
            }
        }
        loaded = true
    }

    public func enqueue(_ item: SyncQueueItem) {
        // De-dupe by entityId + kind so repeated dirty-marks don't pile up.
        if !items.contains(where: { $0.entityId == item.entityId && $0.kind == item.kind }) {
            items.append(item)
        }
    }

    public func peek() -> SyncQueueItem? { items.first }

    public func dequeueNext(limit: Int) -> [SyncQueueItem] {
        let n = min(max(limit, 0), items.count)
        guard n > 0 else { return [] }
        let head = Array(items.prefix(n))
        items.removeFirst(n)
        return head
    }

    public func pendingCount() -> Int { items.count }

    public func isLoaded() -> Bool { loaded }

    /// Test/diagnostic only — DO NOT call from production paths.
    public func _drainForTests() -> [SyncQueueItem] {
        let copy = items
        items.removeAll()
        return copy
    }

    private struct Pair: Hashable {
        let entityId: UUID
        let kind: SyncEntityKind
    }
}

public struct SyncQueueItem: Sendable, Hashable {
    public let entityId: UUID
    public let kind: SyncEntityKind

    public init(entityId: UUID, kind: SyncEntityKind) {
        self.entityId = entityId
        self.kind = kind
    }
}
