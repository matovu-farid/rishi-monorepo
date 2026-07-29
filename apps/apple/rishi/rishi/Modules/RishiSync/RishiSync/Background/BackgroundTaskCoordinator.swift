import Foundation


// `BGTaskScheduler` is API_UNAVAILABLE(macos) — even on macOS 14 — so we
// gate the real implementation to iOS + macCatalyst. macOS host triple gets
// a stub final class so `swift build` from a developer's macOS machine
// succeeds for the unrelated parts of RishiSync.
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))

import BackgroundTasks

/// Wraps `BGTaskScheduler` for register + schedule + launch-handler routing.
///
/// **SYNC-05** — book uploads via `BGProcessingTask` (charger + Wi-Fi,
/// multi-minute budget).
/// **SYNC-06 fallback** — opportunistic refresh via `BGAppRefreshTask`
/// (~30s budget on cellular, every ~1h).
///
/// Identifiers MUST match Info.plist's `BGTaskSchedulerPermittedIdentifiers`
/// exactly — the OS rejects a mismatch at first-launch with a fatal log.
///
/// Tests inject a custom `Surface` so the real `BGTaskScheduler` is never
/// touched in unit tests.
@MainActor
public final class BackgroundTaskCoordinator {

    public static let processingIdentifier = "org.fidexa.rishi.sync.processing"
    public static let refreshIdentifier    = "org.fidexa.rishi.sync.refresh"

    /// Indirection over `BGTaskScheduler` so tests inject a fake.
    @MainActor
    public protocol Surface {
        func register(forTaskWithIdentifier id: String, using queue: DispatchQueue?, launchHandler: @MainActor @escaping (BGTask) -> Void) -> Bool
        func submit(_ request: BGTaskRequest) throws
    }

    /// Production surface — forwards to `BGTaskScheduler.shared`.
    @MainActor
    public struct SystemSurface: Surface {
        public init() {}
        public func register(forTaskWithIdentifier id: String, using queue: DispatchQueue?, launchHandler: @MainActor @escaping (BGTask) -> Void) -> Bool {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: queue) { task in
                // KEEP: BGTaskScheduler invokes launchHandler on an internal
                // queue. The launchHandler closure here is @MainActor (Surface
                // protocol contract) so the hop is required to satisfy the
                // isolation; the actual sync work in handleProcessing/handleRefresh
                // is offloaded via runTask below.
                Task { @MainActor in launchHandler(task) }
            }
        }
        public func submit(_ request: BGTaskRequest) throws {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    private let surface: any Surface
    private let engine: SyncEngine
    private let config: SyncEngineConfig

    public init(engine: SyncEngine, config: SyncEngineConfig = .init(), surface: any Surface = SystemSurface()) {
        self.engine = engine
        self.config = config
        self.surface = surface
    }

    /// Call once on app launch from `rishiApp.init` — MUST precede
    /// `UIApplication.didFinishLaunching` per Apple's BGTask registration
    /// contract. Returns `true` only when both BGTask identifiers register
    /// successfully.
    @discardableResult
    public func register() -> Bool {
        let result = Self.register(surface: surface) { [weak self] task in
            guard let self else { task.setTaskCompleted(success: false); return }
            self.handle(task: task)
        }
        Log.event("sync.bg.registered", level: .info, data: [
            "processing": String(result.processing),
            "refresh": String(result.refresh),
        ])
        return result.processing && result.refresh
    }

    public static func register(
        surface: any Surface,
        handler: @MainActor @escaping (BGTask) -> Void
    ) -> (processing: Bool, refresh: Bool) {
        let processing = surface.register(
            forTaskWithIdentifier: processingIdentifier,
            using: nil,
            launchHandler: handler
        )
        let refresh = surface.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil,
            launchHandler: handler
        )
        return (processing, refresh)
    }

    /// Submit one BGProcessingTaskRequest + one BGAppRefreshTaskRequest.
    /// Re-call after every successful wave so the OS has a fresh budget.
    public func scheduleAll() {
        Self.scheduleAll(surface: surface, config: config)
    }

    public static func scheduleAll(surface: any Surface, config: SyncEngineConfig = .init()) {
        do {
            let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
            processing.requiresNetworkConnectivity = true   // book uploads need network
            processing.requiresExternalPower = false
            try surface.submit(processing)

            let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: config.backgroundRefreshInterval)
            try surface.submit(refresh)
            Log.event("sync.bg.scheduled", level: .info, data: [
                "refresh_interval_s": String(Int(config.backgroundRefreshInterval)),
            ])
        } catch {
            Log.error("sync.bg.schedule.failed", error: error)
        }
    }

    // MARK: - Launch handlers

    private func handle(task: BGTask) {
        // KEEP: runTask is the off-main sync wave; `engine` is an actor so the
        // body runs on the engine's executor, not main. The coordinator itself
        // is @MainActor so we need main only for the BGTask completion call.
        let runTask = Task { [engine] in
            let wave = await engine.runOnce()
            return wave.errors.isEmpty
        }
        task.expirationHandler = { runTask.cancel() }
        // KEEP: BGTask.setTaskCompleted(success:) and the @MainActor scheduleAll
        // both require MainActor isolation; explicit hop after awaiting the
        // off-main runTask.value.
        Task { @MainActor in
            let ok = await runTask.value
            task.setTaskCompleted(success: ok)
            self.scheduleAll() // re-arm
        }
    }

}

#else

/// macOS host-triple stub so `swift build` from a dev machine succeeds for
/// the rest of RishiSync. Real BG behavior only exists on iOS / iPadOS /
/// macCatalyst. The Info.plist identifiers stay in sync as static constants
/// so non-BG call-sites can still reference them.
@MainActor
public final class BackgroundTaskCoordinator {
    public static let processingIdentifier = "org.fidexa.rishi.sync.processing"
    public static let refreshIdentifier    = "org.fidexa.rishi.sync.refresh"

    public init(engine: SyncEngine, config: SyncEngineConfig = .init()) {}

    @discardableResult public func register() -> Bool { false }
    public func scheduleAll() {}
}

#endif
