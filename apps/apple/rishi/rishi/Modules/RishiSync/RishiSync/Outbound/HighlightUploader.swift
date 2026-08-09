import Foundation




/// Pushes pending highlights to /api/sync/push.
///
/// SYNC-01 (highlights family). Highlights pulled out of HighlightStore are
/// pushed as live changes; queued ids without a backing row are tombstoned
/// via `deleted=true` so the worker can propagate the delete to other devices.
public final class HighlightUploader: Sendable {

    public enum UploadError: Error, Sendable {
        case encodingFailed(String)
    }

    private let workerClient: WorkerClient
    private let highlightStore: any HighlightStore
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        highlightStore: any HighlightStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.highlightStore = highlightStore
        self.metadataStore = metadataStore
    }

    /// Push the given items in a single batch. Returns the total count of
    /// rows touched (live + tombstones).
    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        var changes: [SyncChange] = []
        var liveIds: [UUID] = []
        var tombstoneIds: [UUID] = []
        var expectedDirtyAt: [UUID: Date] = [:]

        for item in items where item.kind == .highlight {
            let capturedDirtyAt = try await metadataStore.dirtyAt(entityId: item.entityId, kind: .highlight)
            expectedDirtyAt[item.entityId] = capturedDirtyAt
            if let highlight = try await highlightStore.highlight(item.entityId) {
                do {
                    let payload = try SyncPayloadCodec.encodeHighlight(highlight)
                    changes.append(SyncChange(
                        kind: SyncEntityKind.highlight.rawValue,
                        id: highlight.id,
                        payload: payload,
                        // v1 highlights don't carry updatedAt; createdAt is monotone enough
                        // for "newest wins" merge-by-id resolution in ChangeApplier.
                        updatedAt: capturedDirtyAt ?? highlight.createdAt,
                        deleted: false
                    ))
                    liveIds.append(item.entityId)
                } catch {
                    throw UploadError.encodingFailed(String(describing: error))
                }
            } else {
                // Local row gone → tombstone so the worker mirrors the delete.
                changes.append(SyncChange(
                    kind: SyncEntityKind.highlight.rawValue,
                    id: item.entityId,
                    payload: SyncOpaqueJSON(data: Data("{}".utf8)),
                    updatedAt: capturedDirtyAt ?? Date(),
                    deleted: true
                ))
                tombstoneIds.append(item.entityId)
            }
        }

        guard !changes.isEmpty else { return 0 }

        let response = try await workerClient.send(SyncPushEndpoint(body: .init(changes: changes)))
        Log.event("sync.highlight.push.completed", level: .info, data: [
            "count": String(changes.count),
            "tombstones": String(tombstoneIds.count),
        ])

        var acknowledgedCount = 0
        for id in liveIds {
            if try await metadataStore.markCleanIfUnchanged(
                entityId: id,
                kind: .highlight,
                expectedDirtyAt: expectedDirtyAt[id],
                lastSyncedAt: response.acceptedAt,
                remoteEtag: nil
            ) { acknowledgedCount += 1 }
        }
        for id in tombstoneIds {
            if try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: id,
                kind: .highlight,
                expectedDirtyAt: expectedDirtyAt[id],
                lastSyncedAt: response.acceptedAt,
                remoteEtag: nil
            ) {
                acknowledgedCount += 1
            }
        }
        return acknowledgedCount
    }
}
