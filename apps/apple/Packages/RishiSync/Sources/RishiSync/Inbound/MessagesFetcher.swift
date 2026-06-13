import Foundation
import RishiAPI
import RishiCore
import RishiLogging

/// Phase 16-05 — pulls newer messages since the per-resource watermark.
///
/// Mirrors `ConversationsFetcher` posture. Messages are append-only locally;
/// the wire shape carries an `updated_at` mirror of `created_at` (the worker
/// owns LWW conflict resolution via `(id, updated_at)`) — locally we drop
/// `updated_at` and derive only `createdAt` from the wire.
///
/// Rows whose `role` string doesn't decode into a `MessageRole` (`user` /
/// `assistant` / `system`) are silently dropped — defensive against a
/// future worker emitting an unknown role rather than crashing the wave.
public final class MessagesFetcher: Sendable {

    private let workerClient: WorkerClient
    private let metadataStore: any SyncMetadataStore

    public init(workerClient: WorkerClient, metadataStore: any SyncMetadataStore) {
        self.workerClient = workerClient
        self.metadataStore = metadataStore
    }

    /// Fetch all message rows newer than the persisted watermark. Returns the
    /// decoded `Message` array; the caller is responsible for persisting
    /// via `MessageStore.upsert` and advancing the watermark via
    /// `metadataStore.markClean`.
    public func fetch() async throws -> [Message] {
        let cursor = try await metadataStore.lastSyncedAt(forKind: .message)
        let sinceMs: Int64? = cursor.map { Int64($0.timeIntervalSince1970 * 1000) }
        Log.event("sync.messages.fetch.started", level: .info, data: [
            "since_ms": sinceMs.map(String.init) ?? "nil",
        ])
        let response = try await workerClient.send(MessagesSyncSinceEndpoint(since: sinceMs))
        Log.event("sync.messages.fetch.completed", level: .info, data: [
            "count": String(response.rows.count),
        ])
        return response.rows.compactMap { row -> Message? in
            guard let role = MessageRole(rawValue: row.role) else { return nil }
            return Message(
                id: row.id,
                conversationId: row.conversationId,
                role: role,
                content: row.content,
                toolCalls: nil,
                createdAt: Date(timeIntervalSince1970: Double(row.createdAt) / 1000.0)
            )
        }
    }
}
