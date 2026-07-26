import Foundation


/// Whether the server's entitlement snapshot has been fetched (or hydrated
/// from per-user cache) for the current account session.
@available(iOS 18.4, macOS 15.4, *)
public enum EntitlementSnapshotResolution: Sendable, Equatable {
    case unresolved
    case resolved(EntitlementSnapshot, fetchedAt: Date)

    public var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }

    public var resolvedSnapshot: EntitlementSnapshot? {
        if case .resolved(let snapshot, _) = self { return snapshot }
        return nil
    }

    public var fetchedAt: Date? {
        if case .resolved(_, let fetchedAt) = self { return fetchedAt }
        return nil
    }
}
