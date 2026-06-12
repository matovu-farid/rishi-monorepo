import Foundation
import RishiAPI
import RishiCore
import RishiLogging

/// Phase 16-05 — pulls newer conversations since the per-resource watermark.
///
/// Mirrors `RemoteChangeFetcher`'s posture: thin — owns the cursor read
/// and the endpoint call, nothing else. `SyncEngine.runOnce` drives the
/// inbound merge directly (no `ChangeApplier` hop) because chat sync is
/// served by dedicated `/api/sync/conversations` + `/api/sync/messages`
/// endpoints rather than the legacy `/api/sync/changes` envelope.
///
/// Wire shape: `ms_epoch` (Int64) — matches the worker's Drizzle column
/// type and the existing electron/mobile chat sync convention. We pass
/// the watermark as ms-since-epoch and decode `created_at` / `updated_at`
/// back into `Date` by dividing by 1000.
///
/// The local `Conversation.bookId` is `Optional<UUID>`; the worker schema
/// column is non-null and uses the all-zero UUID as a sentinel for
/// "no book". The reverse-mapping here is the mirror of
/// `ConversationUploader`'s outbound mapping.
public final class ConversationsFetcher: @unchecked Sendable {

    /// All-zero UUID sentinel for `bookId == nil` on the wire. Matches the
    /// `ConversationUploader.nilBookIdSentinel` constant — kept duplicated
    /// rather than shared to keep the two files independently auditable.
    private static let nilBookIdSentinel: String = "00000000-0000-0000-0000-000000000000"

    private let workerClient: WorkerClient
    private let metadataStore: any SyncMetadataStore

    public init(workerClient: WorkerClient, metadataStore: any SyncMetadataStore) {
        self.workerClient = workerClient
        self.metadataStore = metadataStore
    }

    /// Fetch all conversation rows newer than the persisted watermark. Returns
    /// the decoded `Conversation` array; the caller is responsible for
    /// persisting via `ConversationStore.upsert` and advancing the watermark
    /// via `metadataStore.markClean`.
    public func fetch() async throws -> [Conversation] {
        let cursor = try await metadataStore.lastSyncedAt(forKind: .conversation)
        let sinceMs: Int64? = cursor.map { Int64($0.timeIntervalSince1970 * 1000) }
        Log.event("sync.conversations.fetch.started", level: .info, data: [
            "since_ms": sinceMs.map(String.init) ?? "nil",
        ])
        let response = try await workerClient.send(ConversationsSyncSinceEndpoint(since: sinceMs))
        Log.event("sync.conversations.fetch.completed", level: .info, data: [
            "count": String(response.rows.count),
        ])
        return response.rows.map { row -> Conversation in
            // Sentinel reverse-mapping: zero UUID on the wire → nil locally.
            let mappedBookId: UUID? = {
                if row.bookId == Self.nilBookIdSentinel { return nil }
                return UUID(uuidString: row.bookId)
            }()
            // userId is a UUID-shaped String on the wire; tolerate malformed
            // by falling back to a fresh UUID (worker should never emit a
            // non-UUID user_id, but local mapping should not crash).
            let mappedUserId = UUID(uuidString: row.userId) ?? UUID()
            return Conversation(
                id: row.id,
                userId: mappedUserId,
                bookId: mappedBookId,
                title: row.title,
                createdAt: Date(timeIntervalSince1970: Double(row.createdAt) / 1000.0),
                updatedAt: Date(timeIntervalSince1970: Double(row.updatedAt) / 1000.0)
            )
        }
    }
}
