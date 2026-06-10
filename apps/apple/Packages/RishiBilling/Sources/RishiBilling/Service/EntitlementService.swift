import Foundation
import RishiAPI
import RishiLogging

/// Caches the user's current entitlement and exposes it as an `AsyncStream`.
///
/// BILL-01: Pro features check entitlement from `/api/auth/get-session`
/// (cached locally for offline UI). UI subscribes to ``currentLevel`` once at
/// view appearance; the service yields the cached value immediately, then
/// any further `refresh()` result.
///
/// Cache: `UserDefaults` under `"billing.entitlement.level"`. String rawValue
/// so missing / corrupt reads fall back to `.free` (safe default — never
/// silently grant Pro to a free user).
public actor EntitlementService {

    /// Continuous stream of entitlement values. The first subscriber always
    /// receives the hydrated cache immediately so SwiftUI bindings don't
    /// flicker offline. Each subsequent ``refresh()`` or ``setCached(_:)``
    /// yields exactly once when the value changes.
    public nonisolated let currentLevel: AsyncStream<EntitlementLevel>
    private let continuation: AsyncStream<EntitlementLevel>.Continuation

    private let workerClient: WorkerClient
    private let defaults: UserDefaults
    private var latest: EntitlementLevel

    /// UserDefaults key used for the cache. Stable contract — Plan 11-06
    /// references this key when wiring app launch hydration.
    public static let defaultsKey = "billing.entitlement.level"

    public init(
        workerClient: WorkerClient,
        defaults: UserDefaults = .standard
    ) {
        self.workerClient = workerClient
        self.defaults = defaults

        // Hydrate from cache. Missing / unknown rawValue → .free.
        let cachedRaw = defaults.string(forKey: Self.defaultsKey)
        let cached = cachedRaw.flatMap(EntitlementLevel.init(rawValue:)) ?? .free
        self.latest = cached

        var continuation: AsyncStream<EntitlementLevel>.Continuation!
        self.currentLevel = AsyncStream { c in continuation = c }
        self.continuation = continuation
        // Yield the cached value so any consumer subscribing immediately
        // after init sees a value without waiting for a refresh.
        continuation.yield(cached)
    }

    /// Synchronously seed the cache (e.g. when the auth service hands back
    /// a `SessionUser` with a known `hasPro` value). Bypasses the network.
    ///
    /// No-op when `level` matches the current cached value — avoids spurious
    /// stream emissions.
    public func setCached(_ level: EntitlementLevel) {
        guard level != latest else { return }
        latest = level
        defaults.set(level.rawValue, forKey: Self.defaultsKey)
        continuation.yield(level)
        Log.event("billing.entitlement.cached", level: .info, data: ["level": level.rawValue])
    }

    /// Hit `/api/auth/get-session` and update cache + stream. Transport errors
    /// are logged but DO NOT clobber the cache — offline reads stay valid.
    @discardableResult
    public func refresh() async -> Result<EntitlementLevel, Error> {
        do {
            let response = try await workerClient.send(GetSessionEndpoint())
            let level = EntitlementLevel(hasPro: response.hasPro)
            setCached(level)
            return .success(level)
        } catch {
            Log.event("billing.entitlement.refresh_failed", level: .warning,
                      data: ["error": String(describing: error)])
            return .failure(error)
        }
    }

    /// Snapshot accessor for code paths that need a synchronous read
    /// (e.g. SwiftUI body that can't await). Always reflects the latest
    /// value yielded into the stream.
    public func snapshot() -> EntitlementLevel { latest }
}
