import Foundation
import RishiCore
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
@available(iOS 18.4, macOS 15.4, *)
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

    // MARK: - Server-owned entitlement snapshot (GET /api/billing/me)
    //
    // Added 2026-07-17 alongside the above. This is a SEPARATE, PARALLEL
    // entitlement model — `EntitlementLevel` (binary, on-device-StoreKit-
    // adjacent) and `EntitlementSnapshot` (the Worker's 5-state trial/paid/
    // expired union) answer different questions and are deliberately not
    // merged. See docs/superpowers/plans/2026-07-17-entitlement-snapshot-
    // client.md's "Design decisions" #1.

    /// Continuous stream of the server's entitlement snapshot. Unlike
    /// ``currentLevel``, this is NOT persisted to `UserDefaults` — there is
    /// no safe "last known" value that isn't itself stale, and the Worker's
    /// `Cache-Control: private, max-age=30, must-revalidate` header already
    /// governs staleness server-side. The first subscriber sees
    /// ``EntitlementSnapshot/trialExhausted`` (see ``latestSnapshot``'s doc
    /// comment) until the first ``refreshSnapshot()`` completes.
    public nonisolated let currentSnapshot: AsyncStream<EntitlementSnapshot>
    private let snapshotContinuation: AsyncStream<EntitlementSnapshot>.Continuation

    /// Safe placeholder until the first successful ``refreshSnapshot()``.
    /// `.trialExhausted` is chosen deliberately: it blocks AI-feature
    /// affordances (never show a Voice Chat / narration entry point before
    /// the server has actually confirmed an allowance) without blocking
    /// core reading, which per spec is never gated on entitlement state.
    private var latestSnapshot: EntitlementSnapshot = .trialExhausted

    public init(
        workerClient: WorkerClient,
        defaults: UserDefaults = .standard
    ) {
        self.workerClient = workerClient
        self.defaults = defaults

        // Hydrate from cache. Missing / unknown rawValue → .free.
        let cachedRaw = defaults.string(forKey: Self.defaultsKey)
        let cached = cachedRaw.flatMap(EntitlementLevel.init(rawValue:)) ?? .unsubscribed
        self.latest = cached

        var continuation: AsyncStream<EntitlementLevel>.Continuation!
        self.currentLevel = AsyncStream { c in continuation = c }
        self.continuation = continuation
        // Yield the cached value so any consumer subscribing immediately
        // after init sees a value without waiting for a refresh.
        continuation.yield(cached)

        var snapshotContinuation: AsyncStream<EntitlementSnapshot>.Continuation!
        self.currentSnapshot = AsyncStream { c in snapshotContinuation = c }
        self.snapshotContinuation = snapshotContinuation
        snapshotContinuation.yield(latestSnapshot)
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
    ///
    /// Better Auth returns literal JSON `null` for unauthenticated callers,
    /// which decodes as `nil`. That is NOT an error — it just means "no
    /// session, free tier". Only thrown errors (transport, 4xx/5xx, decode
    /// failures on a non-null body) flow into `.failure`.
    @discardableResult
    public func refresh() async -> Result<EntitlementLevel, Error> {
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

    /// Clear the cached entitlement on sign-out so the next user does not
    /// briefly inherit the previous user's Pro state before a server refresh.
    /// Resets to `.free`, persists `.free` (so a relaunch before any refresh
    /// shows free), and yields `.free` to the stream. Always emits even when
    /// already `.free`, since sign-out must guarantee a clean baseline.
    public func clearCache() {
        latest = .unsubscribed
        defaults.set(EntitlementLevel.unsubscribed.rawValue, forKey: Self.defaultsKey)
        continuation.yield(.unsubscribed)
        Log.event("billing.entitlement.cleared", level: .info)
    }

    /// Snapshot accessor for code paths that need a synchronous read
    /// (e.g. SwiftUI body that can't await). Always reflects the latest
    /// value yielded into the stream.
    public func snapshot() -> EntitlementLevel { latest }

    // MARK: - Server-owned entitlement snapshot (continued)

    /// Hit `GET /api/billing/me` and update ``latestSnapshot``/``currentSnapshot``.
    /// Called at launch and foreground — see `rishiApp.swift`. Does not
    /// clobber ``latestSnapshot`` on failure, matching ``refresh()``'s
    /// "offline reads stay valid" contract. An unauthenticated caller (no
    /// stored session) fails here like any other network error; callers
    /// that only want to refresh for signed-in users must check that
    /// themselves first (see `rishiApp.swift`'s launch/foreground hook).
    @discardableResult
    public func refreshSnapshot() async -> Result<EntitlementSnapshot, Error> {
        do {
            let snapshot = try await workerClient.send(BillingMeEndpoint())
            latestSnapshot = snapshot
            snapshotContinuation.yield(snapshot)
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

    /// Synchronous snapshot accessor, matching ``snapshot()``'s shape for
    /// the binary `EntitlementLevel` above.
    public func snapshotNow() -> EntitlementSnapshot { latestSnapshot }
}
