import Foundation




/// Pulls server-side changes since the global cursor.
///
/// SYNC-02: Library, positions, highlights, conversations sync down on first launch.
///
/// The fetcher is intentionally thin — it owns the cursor read and the
/// endpoint call, nothing else. `ChangeApplier` (this package) is the next
/// step in the engine's inbound wave and turns `[SyncChange]` into local
/// store writes with conflict resolution.
public final class RemoteChangeFetcher: Sendable {

    private enum ScopeMismatch: Error, CustomStringConvertible {
        case expected(SyncCursorScope, actual: SyncCursorScope)

        var description: String {
            switch self {
            case let .expected(expected, actual):
                return "sync cursor scope mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
            }
        }
    }

    private let workerClient: WorkerClient
    private let metadataStore: any SyncMetadataStore

    public init(workerClient: WorkerClient, metadataStore: any SyncMetadataStore) {
        self.workerClient = workerClient
        self.metadataStore = metadataStore
    }

    public func fetch() async throws -> [SyncChange] {
        return try await fetchSnapshot().changes
    }

    /// Fetches one cursor page. The fetcher is intentionally read-only: the
    /// caller commits `page.nextCursor` only after applying the page safely.
    /// A nil cursor requests the Worker's initial cursor page; old Workers
    /// return their legacy one-page envelope, which decodes through the same
    /// additive response defaults.
    public func fetchPage(
        scope: SyncCursorScope,
        cursor: String?
    ) async throws -> SyncChangesPage {
        let response = try await workerClient.send(SyncChangesEndpoint(scope: scope, cursor: cursor))
        if let responseScope = response.cursorScope, responseScope != scope {
            throw ScopeMismatch.expected(scope, actual: responseScope)
        }
        Log.event("sync.fetch.page.completed", level: .info, data: [
            "scope": scope.rawValue,
            "count": String(response.changes.count),
            "has_more": String(response.hasMore),
            "projection_complete": String(response.projectionComplete),
        ])
        return response
    }

    public func fetchSnapshot() async throws -> SyncObject {
        let since = try await metadataStore.globalLastSyncedAt()
        Log.event("sync.fetch.started", level: .info, data: [
            "since": since.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
        ])
        let response = try await workerClient.send(SyncChangesEndpoint(since: since))
        Log.event("sync.fetch.completed", level: .info, data: [
            "count": String(response.changes.count),
            "snapshot_hash": response.snapshotHash ?? "unavailable",
            "snapshot_hash_without_timestamps": response.snapshotHashWithoutTimestamps ?? "unavailable",
        ])
        return SyncObject(
            changes: response.changes,
            remoteHash: response.snapshotHashWithoutTimestamps,
            isTruncated: response.isTruncated
        )
    }

    /// Fetches the complete generated projection without advancing the local
    /// cursor. Used after outbound mutations for convergence verification.
    public func fetchFullSnapshot() async throws -> SyncObject {
        let response = try await workerClient.send(SyncChangesEndpoint(since: nil))
        return SyncObject(
            changes: response.changes,
            remoteHash: response.snapshotHashWithoutTimestamps,
            isTruncated: response.isTruncated
        )
    }
}
