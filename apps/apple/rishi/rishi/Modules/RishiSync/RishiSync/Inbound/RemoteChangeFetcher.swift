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

    private let workerClient: WorkerClient
    private let metadataStore: any SyncMetadataStore

    public init(workerClient: WorkerClient, metadataStore: any SyncMetadataStore) {
        self.workerClient = workerClient
        self.metadataStore = metadataStore
    }

    public func fetch() async throws -> [SyncChange] {
        let since = try await metadataStore.globalLastSyncedAt()
        Log.event("sync.fetch.started", level: .info, data: [
            "since": since.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
        ])
        let response = try await workerClient.send(SyncChangesEndpoint(since: since))
        Log.event("sync.fetch.completed", level: .info, data: [
            "count": String(response.changes.count),
        ])
        return response.changes
    }
}
