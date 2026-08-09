import Foundation




/// Pushes pending bookmarks to /api/sync/push.
///
/// Phase 37-08 (BMK-05 client half) — clone of `HighlightUploader`. Bookmarks
/// pulled out of `BookmarkStore` are pushed as live changes; queued ids without
/// a backing row are tombstoned via `deleted=true` so the worker can propagate
/// the delete to other devices. The wire shape (kind "bookmark", snake_case
/// payload, ISO8601 `created_at`) matches the 37-07 worker half byte-for-byte.
public final class BookmarkUploader: Sendable {

    public enum UploadError: Error, Sendable {
        case encodingFailed(String)
    }

    private let workerClient: WorkerClient
    private let bookmarkStore: any BookmarkStore
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        bookmarkStore: any BookmarkStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.bookmarkStore = bookmarkStore
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

        for item in items where item.kind == .bookmark {
            let capturedDirtyAt = try await metadataStore.dirtyAt(entityId: item.entityId, kind: .bookmark)
            expectedDirtyAt[item.entityId] = capturedDirtyAt
            if let bookmark = try await bookmarkStore.bookmark(item.entityId) {
                do {
                    let payload = try SyncPayloadCodec.encodeBookmark(bookmark)
                    changes.append(SyncChange(
                        kind: SyncEntityKind.bookmark.rawValue,
                        id: bookmark.id,
                        payload: payload,
                        // Bookmarks don't carry updatedAt; createdAt is the
                        // monotone LWW key (ChangeApplier.applyBookmark compares it).
                        updatedAt: capturedDirtyAt ?? bookmark.createdAt,
                        deleted: false
                    ))
                    liveIds.append(item.entityId)
                } catch {
                    throw UploadError.encodingFailed(String(describing: error))
                }
            } else {
                // Local row gone -> tombstone so the worker mirrors the delete.
                changes.append(SyncChange(
                    kind: SyncEntityKind.bookmark.rawValue,
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
        Log.event("sync.bookmark.push.completed", level: .info, data: [
            "count": String(changes.count),
            "tombstones": String(tombstoneIds.count),
        ])

        var acknowledgedCount = 0
        for id in liveIds {
            if try await metadataStore.markCleanIfUnchanged(
                entityId: id,
                kind: .bookmark,
                expectedDirtyAt: expectedDirtyAt[id],
                lastSyncedAt: response.acceptedAt,
                remoteEtag: nil
            ) { acknowledgedCount += 1 }
        }
        for id in tombstoneIds {
            if try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: id,
                kind: .bookmark,
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
