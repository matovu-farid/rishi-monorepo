import Foundation

/// Sync-engine tunables. All knobs `Sendable` so the engine can hold the
/// value across actor hops.
public struct SyncEngineConfig: Sendable {
    /// SYNC-03 debounce window for `markPositionDirty`. 1s in production.
    public var positionDebounceWindow: TimeInterval

    /// Per-kind batch ceiling when draining the queue in a single wave.
    public var batchLimit: Int

    /// `BGAppRefreshTaskRequest.earliestBeginDate` offset.
    public var backgroundRefreshInterval: TimeInterval

    public init(
        positionDebounceWindow: TimeInterval = 1.0,
        batchLimit: Int = 50,
        backgroundRefreshInterval: TimeInterval = 3600
    ) {
        self.positionDebounceWindow = positionDebounceWindow
        self.batchLimit = batchLimit
        self.backgroundRefreshInterval = backgroundRefreshInterval
    }
}
