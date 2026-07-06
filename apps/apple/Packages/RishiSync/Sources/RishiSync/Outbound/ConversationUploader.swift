import Foundation
import RishiCore
import RishiCore
import RishiLogging

/// Pushes pending conversations to `/api/sync/conversations`.
///
/// Phase 16-04 — closes the `SyncEngine.runOnce` no-op for `.conversation`.
/// Mirrors `PositionUploader`'s stale-drain + markClean-on-200 contract:
///   - Items whose local row is missing are silently `markClean`'d so the
///     queue stops surfacing them.
///   - On 2xx, every accepted id is `markClean`'d.
///   - On 4xx/5xx the error is thrown so `SyncEngine` re-enqueues the bucket
///     for the next wave.
///
/// `Conversation.bookId` is optional locally (`nil` when the chat isn't book-
/// anchored); the worker schema column is non-null, so a sentinel zero-UUID
/// represents "no book" on the wire. The worker translates the sentinel back
/// to NULL for incremental pulls.
public final class ConversationUploader: Sendable {

    public enum UploadError: Error, Sendable {
        case encodingFailed(String)
    }

    /// All-zero UUID sentinel for `bookId == nil`. Wire format: lowercase
    /// canonical 8-4-4-4-12 hex (matches `UUID()` `description` of a zero UUID).
    private static let nilBookIdSentinel: String = "00000000-0000-0000-0000-000000000000"

    private let workerClient: WorkerClient
    private let conversationStore: any ConversationStore
    private let metadataStore: any SyncMetadataStore

    public init(
        workerClient: WorkerClient,
        conversationStore: any ConversationStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.workerClient = workerClient
        self.conversationStore = conversationStore
        self.metadataStore = metadataStore
    }

    /// Push the given items in a single batch. Returns the count of items
    /// the worker accepted (live rows; stale-drain entries are not counted).
    @discardableResult
    public func pushPending(items: [SyncQueueItem]) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        var rows: [ConversationRowWire] = []
        var resolvedIds: [UUID] = []
        var droppedIds: [UUID] = []

        for item in items where item.kind == .conversation {
            guard let convo = try await conversationStore.conversation(item.entityId) else {
                droppedIds.append(item.entityId)
                continue
            }
            rows.append(ConversationRowWire(
                id: convo.id,
                userId: convo.userId.uuidString,
                bookId: convo.bookId?.uuidString.lowercased() ?? Self.nilBookIdSentinel,
                title: convo.title,
                archived: false,
                createdAt: Int64(convo.createdAt.timeIntervalSince1970 * 1000),
                updatedAt: Int64(convo.updatedAt.timeIntervalSince1970 * 1000)
            ))
            resolvedIds.append(convo.id)
        }

        // Drain stale (locally-deleted) items so the queue stops surfacing them.
        let now = Date()
        for id in droppedIds {
            try await metadataStore.markClean(
                entityId: id,
                kind: .conversation,
                lastSyncedAt: now,
                remoteEtag: nil
            )
        }

        guard !rows.isEmpty else { return 0 }

        let response = try await workerClient.send(
            ConversationsSyncEndpoint(body: .init(conversations: rows))
        )
        Log.event("sync.conversation.push.completed", level: .info, data: [
            "count": String(resolvedIds.count),
            "applied": String(response.appliedCount),
        ])
        for id in resolvedIds {
            try await metadataStore.markClean(
                entityId: id,
                kind: .conversation,
                lastSyncedAt: now,
                remoteEtag: nil
            )
        }
        return resolvedIds.count
    }
}
