import Foundation


@available(iOS 18.4, macOS 15.4, *)
public enum EntitlementAIGate {
    public static let refreshInterval: TimeInterval = 30

    static func snapshotAfterRefresh(
        _ refreshResult: Result<EntitlementSnapshot, Error>?,
        fallingBackTo storedSnapshot: EntitlementSnapshot?
    ) -> EntitlementSnapshot? {
        if case .success(let refreshedSnapshot) = refreshResult {
            return refreshedSnapshot
        }
        return storedSnapshot
    }

    public static func needsRefreshBeforeGate(
        resolution: EntitlementSnapshotResolution
    ) -> Bool {
        switch resolution {
        case .unresolved:
            return true
        case .resolved(_, let fetchedAt):
            return Date.now.timeIntervalSince(fetchedAt) > refreshInterval
        }
    }

    /// Refresh when unresolved or stale, then revalidate once more before
    /// showing an exhaustion block.
    @MainActor
    public static func gateAIFeature(
        _ feature: AIFeature,
        store: EntitlementSnapshotStore,
        coordinator: EntitlementRefreshCoordinator
    ) async -> AIFeatureBlockReason? {
        var snapshot = store.resolvedSnapshot
        if needsRefreshBeforeGate(resolution: store.resolution) {
            let refreshResult = await coordinator.refreshIfSignedIn(reason: .aiFeatureTap)
            snapshot = snapshotAfterRefresh(
                refreshResult,
                fallingBackTo: store.resolvedSnapshot
            )
        }
        if snapshot?.blockReason(for: feature) != nil {
            let refreshResult = await coordinator.refreshIfSignedIn(
                reason: .aiFeatureTap,
                force: true
            )
            snapshot = snapshotAfterRefresh(
                refreshResult,
                fallingBackTo: snapshot ?? store.resolvedSnapshot
            )
        }
        return snapshot?.blockReason(for: feature)
    }
}
