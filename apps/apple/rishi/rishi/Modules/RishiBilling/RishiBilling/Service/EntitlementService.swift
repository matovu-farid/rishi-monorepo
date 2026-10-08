import Foundation

public enum EntitlementRefreshError: Error, Sendable {
    case accountChanged
}


/// Caches the user's current entitlement and exposes it as an `AsyncStream`.
///
/// BILL-01: Pro features check entitlement from `/api/auth/get-session`
/// (cached locally for offline UI). UI subscribes to ``currentLevel`` once at
/// view appearance; the service yields the cached value immediately, then
/// any further `refresh()` result.
///
/// Cache: `UserDefaults` under `"billing.entitlement.level"`. String rawValue
/// so missing / corrupt reads fall back to `.unsubscribed` (safe default —
/// never silently grant Pro to a free user).
@available(iOS 18.4, macOS 15.4, *)
public actor EntitlementService {

    /// Continuous stream of entitlement values. The first subscriber always
    /// receives the hydrated cache immediately so SwiftUI bindings don't
    /// flicker offline. Each subsequent ``refresh()`` or ``setCached(_:)``
    /// yields exactly once when the value changes.
    public nonisolated let currentLevel: AsyncStream<EntitlementLevel>
    private let continuation: AsyncStream<EntitlementLevel>.Continuation

    /// Continuous stream of entitlement resolution. Starts `.unresolved`
    /// until ``bindToUser(userId:)`` hydrates cache or ``refreshSnapshot()``
    /// succeeds.
    public nonisolated let currentResolution: AsyncStream<EntitlementSnapshotResolution>
    private let resolutionContinuation: AsyncStream<EntitlementSnapshotResolution>.Continuation

    private let workerClient: WorkerClient
    private let defaults: UserDefaults
    private var latest: EntitlementLevel
    private var latestResolution: EntitlementSnapshotResolution = .unresolved
    private var boundUserId: String?
    private var boundLease: CredentialLease?
    private let credentialAuthority: SessionCredentialAuthority?

    /// Construction-time identity includes the actual transport chain, not
    /// merely a copied credential record with an equal lease value.
    nonisolated func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        credentialAuthority === authority && workerClient.usesCredentialAuthority(authority)
    }


    /// UserDefaults key used for the binary level cache.
    public static let defaultsKey = "billing.entitlement.level"

    private static let snapshotCacheKeyPrefix = "billing.entitlement.snapshot.v1."

    public init(
        workerClient: WorkerClient,
        defaults: UserDefaults = .standard
    ) {
        self.init(workerClient: workerClient, defaults: defaults, stagedAuthority: nil)
    }

    init(workerClient: WorkerClient, defaults: UserDefaults, credentialAuthority: SessionCredentialAuthority) {
        self.init(workerClient: workerClient, defaults: defaults, stagedAuthority: credentialAuthority)
    }

    private init(workerClient: WorkerClient, defaults: UserDefaults, stagedAuthority: SessionCredentialAuthority?) {
        self.workerClient = workerClient
        self.defaults = defaults
        credentialAuthority = stagedAuthority

        let cachedRaw = defaults.string(forKey: Self.defaultsKey)
        let cached = cachedRaw.flatMap(EntitlementLevel.init(rawValue:)) ?? .unsubscribed
        self.latest = cached

        var continuation: AsyncStream<EntitlementLevel>.Continuation!
        self.currentLevel = AsyncStream { c in continuation = c }
        self.continuation = continuation
        continuation.yield(cached)

        var resolutionContinuation: AsyncStream<EntitlementSnapshotResolution>.Continuation!
        self.currentResolution = AsyncStream { c in resolutionContinuation = c }
        self.resolutionContinuation = resolutionContinuation
        resolutionContinuation.yield(.unresolved)
    }

    /// Associate cached snapshot storage with the signed-in user and hydrate
    /// from disk when available.
    public func bindToUser(userId: String) {
        guard credentialAuthority == nil else { return }
        boundUserId = userId
        if let cached = loadCachedResolution(for: userId) {
            setCachedResolution(cached.resolution, fetchedAt: cached.fetchedAt)
        } else {
            setCachedResolution(.unresolved, fetchedAt: nil)
        }
    }

    public func setCached(_ level: EntitlementLevel) {
        guard credentialAuthority == nil else { return }
        guard level != latest else { return }
        latest = level
        defaults.set(level.rawValue, forKey: Self.defaultsKey)
        continuation.yield(level)
        Log.event("billing.entitlement.cached", level: .info, data: ["level": level.rawValue])
    }

    @discardableResult
    public func refresh() async -> Result<EntitlementLevel, Error> {
        guard credentialAuthority == nil else { return .failure(EntitlementRefreshError.accountChanged) }
        do {
            let response = try await workerClient.send(GetSessionEndpoint())
            let level = EntitlementLevel(hasPro: response?.hasPro ?? false)
            setCached(level)
            return .success(level)
        } catch {
            Log.event("billing.entitlement.refresh_failed", level: .warning,
                      data: ["error": String(describing: error)])
            return .failure(error)
        }
    }

    public func clearCache() {
        guard credentialAuthority == nil else { return }
        clearLevelCache()
    }

    private func clearLevelCache() {
        latest = .unsubscribed
        defaults.set(EntitlementLevel.unsubscribed.rawValue, forKey: Self.defaultsKey)
        continuation.yield(.unsubscribed)
        Log.event("billing.entitlement.cleared", level: .info)
    }

    public func snapshot() -> EntitlementLevel { latest }

    @discardableResult
    public func refreshSnapshot(
        expectedUserId: String,
        isCurrentUser: @Sendable @escaping () -> Bool
    ) async -> Result<EntitlementSnapshot, Error> {
        guard credentialAuthority == nil else { return .failure(EntitlementRefreshError.accountChanged) }
        do {
            let snapshot = try await workerClient.send(BillingMeEndpoint())

            guard boundUserId == expectedUserId, isCurrentUser() else {
                if boundUserId == expectedUserId {
                    latestResolution = .unresolved
                    resolutionContinuation.yield(.unresolved)
                }
                return .failure(EntitlementRefreshError.accountChanged)
            }

            let fetchedAt = Date()
            setCachedResolution(.resolved(snapshot, fetchedAt: fetchedAt), fetchedAt: fetchedAt)
            return .success(snapshot)
        } catch {
            Log.event(
                "billing.entitlement_snapshot.refresh_failed",
                level: .warning,
                data: ["error": String(describing: error)]
            )
            return .failure(error)
        }
    }

    public func resolutionNow() -> EntitlementSnapshotResolution { latestResolution }

    /// Clear cached snapshot for a user and reset to unresolved.
    public func clearSnapshotCache(for userId: String? = nil) {
        guard credentialAuthority == nil else { return }
        let targetUserId = userId ?? boundUserId
        if let targetUserId {
            defaults.removeObject(forKey: Self.snapshotCacheKey(for: targetUserId))
        }
        boundUserId = nil
        setCachedResolution(.unresolved, fetchedAt: nil)
    }

    /// Lease validation encloses the actual actor bind/cache publication.
    func bindToUser(userId: String, lease: CredentialLease) -> Bool {
        guard let authority = credentialAuthority, userId == lease.rawUserID else { return false }
        return authority.performIfCurrent(lease) {
            boundUserId = userId
            boundLease = lease
            if let cached = loadCachedResolution(for: userId) {
                setCachedResolution(cached.resolution, fetchedAt: cached.fetchedAt)
            } else {
                setCachedResolution(.unresolved, fetchedAt: nil)
            }
        }
    }

    func refreshSnapshot(lease: CredentialLease) async -> Result<EntitlementSnapshot, Error> {
        guard let authority = credentialAuthority, boundLease == lease,
              authority.isCurrent(lease) else { return .failure(EntitlementRefreshError.accountChanged) }
        do {
            let snapshot = try await workerClient.send(BillingMeEndpoint(), credentialContext: .normal(lease))
            var applied = false
            _ = authority.performIfCurrent(lease) {
                guard boundLease == lease, boundUserId == lease.rawUserID else { return }
                let fetchedAt = Date()
                setCachedResolution(.resolved(snapshot, fetchedAt: fetchedAt), fetchedAt: fetchedAt)
                applied = true
            }
            return applied ? .success(snapshot) : .failure(EntitlementRefreshError.accountChanged)
        } catch {
            return .failure(error)
        }
    }

    /// Used only inside the owning app cleanup reservation. Ordinary lease
    /// publication is already closed while this transition is pending.
    func clearCache(in transition: CredentialTransition) -> Bool {
        guard let authority = credentialAuthority else { return false }
        return authority.performIfCurrent(transition) {
            if case .loaded(let outgoing) = transition.outgoing {
                defaults.removeObject(forKey: Self.snapshotCacheKey(for: outgoing.lease.rawUserID))
            }
            boundUserId = nil
            boundLease = nil
            setCachedResolution(.unresolved, fetchedAt: nil)
            clearLevelCache()
        }
    }

    // MARK: - Private

    private func setCachedResolution(
        _ resolution: EntitlementSnapshotResolution,
        fetchedAt: Date?
    ) {
        latestResolution = resolution
        resolutionContinuation.yield(resolution)
        persistResolutionIfNeeded(resolution, fetchedAt: fetchedAt)
    }

    private func persistResolutionIfNeeded(
        _ resolution: EntitlementSnapshotResolution,
        fetchedAt: Date?
    ) {
        guard let userId = boundUserId else { return }
        switch resolution {
        case .unresolved:
            defaults.removeObject(forKey: Self.snapshotCacheKey(for: userId))
        case .resolved(let snapshot, let resolvedFetchedAt):
            let cachedAt = fetchedAt ?? resolvedFetchedAt
            let payload = CachedEntitlementSnapshotPayload(
                cachedAt: cachedAt,
                snapshot: snapshot
            )
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: Self.snapshotCacheKey(for: userId))
            }
        }
    }

    private func loadCachedResolution(for userId: String) -> (
        resolution: EntitlementSnapshotResolution,
        fetchedAt: Date
    )? {
        guard let data = defaults.data(forKey: Self.snapshotCacheKey(for: userId)),
              let payload = try? JSONDecoder().decode(
                  CachedEntitlementSnapshotPayload.self,
                  from: data
              )
        else { return nil }
        return (
            resolution: .resolved(payload.snapshot, fetchedAt: payload.cachedAt),
            fetchedAt: payload.cachedAt
        )
    }

    private static func snapshotCacheKey(for userId: String) -> String {
        snapshotCacheKeyPrefix + userId
    }
}

@available(iOS 18.4, macOS 15.4, *)
private struct CachedEntitlementSnapshotPayload: Codable {
    let cachedAt: Date
    let snapshot: EntitlementSnapshot
}
