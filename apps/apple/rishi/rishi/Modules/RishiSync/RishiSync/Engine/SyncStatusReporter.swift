import Foundation

/// `SyncStatus` snapshotting, extracted from `SyncEngine` (plan 34-10 SRP).
///
/// Owns the three status mutations the engine previously inlined:
///   - `setRunning(_:on:)` — flip `isRunning`, preserving the other fields;
///     clears `lastError` only on the running edge (`running ? nil : ...`);
///   - `refreshPendingCount(on:)` — re-read `metadataStore.pendingCount()`,
///     keep the rest;
///   - `snapshotStatus(error:on:completedAt:)` — publish the pending count,
///     first wave error, and (only on success) the completion time of the wave.
///
/// The `SyncStatus?` is late-bound on the engine (via `bind(status:)`), so it
/// is passed in per call rather than held — each method is a guard-let no-op
/// when no status is bound, exactly as the inline versions were. The status
/// timestamp intentionally represents wave completion, not the remote cursor.
struct SyncStatusReporter: Sendable {

    private let metadataStore: any SyncMetadataStore

    init(metadataStore: any SyncMetadataStore) {
        self.metadataStore = metadataStore
    }

    func setRunning(_ running: Bool, on status: SyncStatus?) {
        guard let status else { return }
        let now = status.snapshot()
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: now.lastSyncedAt,
            pendingCount: now.pendingCount,
            isRunning: running,
            lastError: running ? nil : now.lastError
        ))
    }

    func refreshPendingCount(on status: SyncStatus?) async {
        guard let status else { return }
        let count = (try? await metadataStore.pendingCount()) ?? 0
        let now = status.snapshot()
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: now.lastSyncedAt,
            pendingCount: count,
            isRunning: now.isRunning,
            lastError: now.lastError
        ))
    }

    func snapshotStatus(error: String?, on status: SyncStatus?, completedAt: Date?) async {
        guard let status else { return }
        let previous = status.snapshot()
        let pending = (try? await metadataStore.pendingCount()) ?? previous.pendingCount
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: error == nil ? (completedAt ?? Date()) : previous.lastSyncedAt,
            pendingCount: pending,
            isRunning: false,
            lastError: error
        ))
    }
}
