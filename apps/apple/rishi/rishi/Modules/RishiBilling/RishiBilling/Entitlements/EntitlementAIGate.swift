import Foundation


@available(iOS 18.4, macOS 15.4, *)
public enum EntitlementAIGate {
    public static let refreshInterval: TimeInterval = 30

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
        if needsRefreshBeforeGate(resolution: store.resolution) {
            await coordinator.refreshIfSignedIn(reason: .aiFeatureTap)
        }
        if store.blockReason(for: feature) != nil {
            await coordinator.refreshIfSignedIn(reason: .aiFeatureTap, force: true)
            return store.blockReason(for: feature)
        }
        return nil
    }
}
