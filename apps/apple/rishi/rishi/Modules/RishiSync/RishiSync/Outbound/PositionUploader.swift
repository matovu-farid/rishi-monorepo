import Foundation




/// Pushes pending positions to /api/sync/push.
///
/// SYNC-03: Position changes debounce-upload during reading.
/// Debounce lives in SyncEngine (07-04) — this uploader is a single-shot batch writer.
///
/// PositionStore is bookId-indexed in v1 (`position(for bookId:)` returns the
/// single Position row for a book), so `SyncQueueItem.entityId` for a pending
/// position carries the BOOK id, not the Position UUID. The metadata row's
/// entity_id thus matches the book id — markClean must use the same id.
public final class PositionUploader: Sendable {

    public enum UploadError: Error, Sendable {
        case encodingFailed(String)
    }

    private let workerClient: WorkerClient
    private let positionStore: any PositionStore
    private let bookStore: any BookStore
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        positionStore: any PositionStore,
        bookStore: any BookStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.positionStore = positionStore
        self.bookStore = bookStore
        self.metadataStore = metadataStore
    }

    /// Push the given items in a single batch. Returns the count of items
    /// the worker accepted (live rows; stale-drain entries are not counted).
    ///
    /// Items whose local row has been deleted are silently markClean'd
    /// against the current time so the queue drains them on the next refresh.
    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        var changes: [SyncChange] = []
        var resolvedIds: [UUID] = []
        var droppedIds: [UUID] = []

        for item in items where item.kind == .position {
            guard let position = try await positionStore.position(for: item.entityId) else {
                droppedIds.append(item.entityId)
                continue
            }
            do {
                let payload = try SyncPayloadCodec.encodePosition(position)
                changes.append(SyncChange(
                    kind: SyncEntityKind.position.rawValue,
                    id: position.id,
                    payload: payload,
                    updatedAt: try await metadataStore.dirtyAt(entityId: item.entityId, kind: .position) ?? position.updatedAt,
                    deleted: false
                ))
                resolvedIds.append(item.entityId)
            } catch {
                throw UploadError.encodingFailed(String(describing: error))
            }
        }

        // Drain stale (deleted-locally) items so the queue stops surfacing them.
        let now = Date()
        for id in droppedIds {
            try await metadataStore.markClean(entityId: id, kind: .position, lastSyncedAt: now, remoteEtag: nil)
        }

        guard !changes.isEmpty else { return 0 }

        let response = try await workerClient.send(SyncPushEndpoint(body: .init(changes: changes)))
        Log.event("sync.position.push.completed", level: .info, data: [
            "count": String(resolvedIds.count),
        ])
        for id in resolvedIds {
            try await metadataStore.markClean(
                entityId: id,
                kind: .position,
                lastSyncedAt: response.acceptedAt,
                remoteEtag: nil
            )
        }
        return resolvedIds.count
    }
}
