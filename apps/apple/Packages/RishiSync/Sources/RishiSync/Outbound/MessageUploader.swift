import Foundation
import RishiAPI
import RishiCore
import RishiLogging

/// Pushes pending messages to `/api/sync/messages`. See `ConversationUploader`
/// for the canonical pattern (stale-drain + markClean-on-200).
///
/// Phase 16-04 — closes the `SyncEngine.runOnce` no-op for `.message`.
///
/// Local `Message` has no `updatedAt` field — messages are append-only on
/// device. The uploader synthesizes `updatedAt = createdAt` at upload time
/// so the wire shape stays uniform with `ConversationRowWire` and the worker
/// can apply LWW conflict resolution off a single `(id, updated_at)` pair
/// across both tables.
public final class MessageUploader: @unchecked Sendable {

    public enum UploadError: Error, Sendable {
        case encodingFailed(String)
    }

    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        messageStore: any MessageStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.metadataStore = metadataStore
    }

    /// Push the given items in a single batch. Returns the count of items
    /// the worker accepted (live rows; stale-drain entries are not counted).
    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        var rows: [MessageRowWire] = []
        var resolvedIds: [UUID] = []
        var droppedIds: [UUID] = []

        for item in items where item.kind == .message {
            guard let msg = try await messageStore.message(item.entityId) else {
                droppedIds.append(item.entityId)
                continue
            }
            let createdMs = Int64(msg.createdAt.timeIntervalSince1970 * 1000)
            rows.append(MessageRowWire(
                id: msg.id,
                conversationId: msg.conversationId,
                role: msg.role.rawValue,
                content: msg.content,
                createdAt: createdMs,
                updatedAt: createdMs        // synthesize: local Message has no updatedAt
            ))
            resolvedIds.append(msg.id)
        }

        // Drain stale (locally-deleted) items so the queue stops surfacing them.
        let now = Date()
        for id in droppedIds {
            try await metadataStore.markClean(
                entityId: id,
                kind: .message,
                lastSyncedAt: now,
                remoteEtag: nil
            )
        }

        guard !rows.isEmpty else { return 0 }

        let response = try await workerClient.send(
            MessagesSyncEndpoint(body: .init(messages: rows))
        )
        Log.event("sync.message.push.completed", level: .info, data: [
            "count": String(resolvedIds.count),
            "applied": String(response.appliedCount),
        ])
        for id in resolvedIds {
            try await metadataStore.markClean(
                entityId: id,
                kind: .message,
                lastSyncedAt: now,
                remoteEtag: nil
            )
        }
        return resolvedIds.count
    }
}
