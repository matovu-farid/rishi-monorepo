//
//  BackgroundSyncLifecycle.swift
//  rishi
//
//  Plan 34-14 SRP split — owns the sync-domain app-lifecycle policy that
//  previously lived inside `AppDependencies` (BGTask registration / drive +
//  the Auto-Sync gate) AND was duplicated in `rishiApp`'s AppDelegate
//  (silent-push gate + bootstrap-race buffering). Both copies of the
//  Auto-Sync gate now live here, in ONE place, behind the pure
//  `shouldRunAutoSync(_:)` decision (defined in ReaderPrefsMenuModel.swift).
//
//  Behaviour-preserving extraction:
//    - The BGTask `register` / `submit` body is byte-for-byte the old
//      `AppDependencies.registerBGTasksSynchronously()`.
//    - `driveBGTask` keeps the exact gate semantics: when Auto-Sync is OFF,
//      report success (the task DID its job — "nothing to do") AND re-arm via
//      `scheduleAll()` so the budget survives.
//    - `handleSilentPush` keeps the exact push semantics: when Auto-Sync is
//      OFF, return `.noData` (honest result, no engine wave).
//    - The bootstrap-race buffering (`if services == nil { await bootstrap() }`)
//      that was duplicated across `driveBGTask`, `didRegisterForRemoteNotifications`
//      and `didReceiveRemoteNotification` is centralised in `resolveServices()`.
//
//  The lifecycle holds a weak reference to the `AppDependencies` composition
//  root (the bootstrap state machine owner) so it can (a) await an in-flight /
//  not-yet-started bootstrap and (b) read the published `services` once they
//  exist — exactly the contract the AppDelegate handlers honoured before.
//

import Foundation
import RishiLogging
import RishiSync
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
import BackgroundTasks
#endif

@MainActor
final class BackgroundSyncLifecycle {

    /// The composition root. `weak` so the lifecycle does not keep the app's
    /// service graph alive past teardown — mirrors the old AppDelegate's
    /// `weak var dependencies`.
    private weak var dependencies: AppDependencies?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Gate policy (pure, testable)

    /// The decision a silent-push wave takes given the Auto-Sync flag. When
    /// Auto-Sync is OFF the wave is skipped — no engine wave runs. Folds the
    /// previously-duplicated AppDelegate copy of the gate into one pure,
    /// `#if`-free seam so a Swift Testing test can pin the on -> run /
    /// off -> skip behaviour without bootstrapping the heavy service graph.
    /// Defers the on/off truth to the shared `shouldRunAutoSync(_:)` so all
    /// auto-sync call sites read ONE gate function.
    static func shouldRunSilentPush(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    /// The decision a BGTask wave takes given the Auto-Sync flag. Mirrors
    /// `shouldRunSilentPush` — when OFF, the BGTask reports success +
    /// re-arms instead of running the engine wave. Same gate condition,
    /// different skip action (success vs `.noData`). Pure + testable.
    static func shouldRunBGTask(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    // MARK: - Bootstrap-race buffering (centralised)

    /// Ensure bootstrap has completed (or an in-flight bootstrap completes
    /// before we proceed), then return the published service graph. Returns
    /// `nil` only if the composition root has been torn down. Production
    /// launch ALWAYS kicks bootstrap from `rishiApp.body`'s `.task`, so the
    /// `bootstrap()` call here is a safety net for OS callbacks that arrive
    /// in the cold-launch window before that `.task` has finished.
    private func resolveServices() async -> BootstrappedServices? {
        guard let deps = dependencies else { return nil }
        if deps.services == nil {
            await deps.bootstrap()
        }
        return deps.services
    }

    // MARK: - BGTask registration (synchronous; honours Apple ordering contract)

    /// Register BGTask launch handlers BEFORE
    /// `application(_:didFinishLaunchingWithOptions:)` returns. Apple's
    /// `BGTaskScheduler` documentation requires registration to happen
    /// inside the launch window; if bootstrap has not yet completed (the
    /// expected case), `driveBGTask` short-circuits to
    /// `task.setTaskCompleted(success: false)` so the OS reschedules the
    /// task for a later wave.
    ///
    /// Called from `RishiAppDelegate.application(_:didFinishLaunching:)`.
    /// The handlers themselves are `@MainActor` per the
    /// `BGTaskScheduler.register(forTaskWithIdentifier:using:)` contract.
    func registerSynchronously() {
        #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
        let processing = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.processingIdentifier,
            using: nil
        ) { [weak self] task in
            // KEEP: BGTaskScheduler hands the BGTask to MainActor by
            // contract; driveBGTask awaits the syncEngine actor on its
            // own executor. Body chains an await — no main-bound IO.
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        let refresh = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            // KEEP: same shape as the processing variant above.
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        Log.event("sync.bg.registered", level: .info, data: [
            "processing": String(processing),
            "refresh": String(refresh),
            "via": "BackgroundSyncLifecycle.registerSynchronously",
        ])

        // Submit the initial BG task requests. `BGTaskScheduler.submit` is
        // safe to call any time after `register`. Launch handlers re-arm
        // on every completion via `BackgroundTaskCoordinator.scheduleAll()`
        // after bootstrap publishes the coordinator.
        do {
            let processingRequest = BGProcessingTaskRequest(
                identifier: BackgroundTaskCoordinator.processingIdentifier
            )
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            try BGTaskScheduler.shared.submit(processingRequest)

            let refreshRequest = BGAppRefreshTaskRequest(
                identifier: BackgroundTaskCoordinator.refreshIdentifier
            )
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
            try BGTaskScheduler.shared.submit(refreshRequest)
            Log.event("sync.bg.scheduled", level: .info)
        } catch {
            Log.error("sync.bg.schedule.failed", error: error)
        }
        #endif
    }

    #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
    /// Common BGTask drive path used by both the processing and refresh
    /// launch handlers registered above. Bootstrap must be complete before
    /// we can drive `syncEngine.runOnce()`; if the OS fires before bootstrap
    /// finishes we await it (it'll be in-flight from `rishiApp.body`'s
    /// `.task` already). After bootstrap completes,
    /// `BackgroundTaskCoordinator.scheduleAll()` re-arms the next wave.
    func driveBGTask(_ task: BGTask) async {
        guard let services = await resolveServices() else {
            task.setTaskCompleted(success: false)
            return
        }
        // Phase 33 plan 33-02 — Auto Sync gate (§G2 site 1). When the user
        // turns Auto Sync OFF, the OS-scheduled background wave is a no-op:
        // report success (the task DID its job — "nothing to do") AND re-arm
        // via scheduleAll() so the budget survives for when the flag flips
        // back on. Manual `syncNow()` is never gated — the gate lives here at
        // the auto call site, not inside SyncEngine.
        guard Self.shouldRunBGTask(autoSync: services.readerDefaults.autoSync) else {
            task.setTaskCompleted(success: true)
            services.backgroundTaskCoordinator.scheduleAll()
            return
        }
        // KEEP: runTask handle is consumed by `task.expirationHandler` for
        // cancellation; the engine.runOnce() body runs on the syncEngine
        // actor's executor. Wrapper body only chains an await + returns Bool.
        let runTask = Task { [engine = services.syncEngine] in
            let wave = await engine.runOnce()
            return wave.errors.isEmpty
        }
        task.expirationHandler = { runTask.cancel() }
        let ok = (try? await runTask.value) ?? false
        task.setTaskCompleted(success: ok)
        services.backgroundTaskCoordinator.scheduleAll()
    }
    #endif

    // MARK: - APNs registration forwarding

    /// Forward an APNs device token to the worker once bootstrap has
    /// published the registrar. Buffers against the bootstrap race exactly
    /// as the old `didRegisterForRemoteNotificationsWithDeviceToken` did.
    func registerDeviceToken(
        _ token: Data,
        platform: String,
        appVersion: String
    ) async {
        guard let registrar = await resolveServices()?.apnsDeviceRegistrar else { return }
        do {
            try await registrar.register(
                token: token,
                platform: platform,
                appVersion: appVersion
            )
        } catch {
            // Silent — engine still works via BGTaskScheduler fallback.
        }
    }

    // MARK: - Silent push

    #if canImport(UIKit)
    /// Route a silent push into the sync engine, honouring the Auto-Sync
    /// gate. Folds the AppDelegate's previous inline copy of the gate +
    /// bootstrap-race buffering into this single sync-lifecycle object.
    ///
    /// Phase 33 plan 33-02 — Auto Sync gate (§G2 site 2). When Auto Sync is
    /// OFF, returning `.noData` is the honest result and avoids the engine
    /// wave. The gate lives here at the auto call site, not inside
    /// `SilentPushHandler` or `SyncEngine`; manual Sync Now is never gated.
    func handleSilentPush(
        _ userInfo: [AnyHashable: Any],
        completion: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) async {
        guard let services = await resolveServices() else {
            completion(.noData)
            return
        }
        guard Self.shouldRunSilentPush(autoSync: services.readerDefaults.autoSync) else {
            completion(.noData)
            return
        }
        SilentPushHandler.handle(
            userInfo,
            engine: services.syncEngine,
            completion: completion
        )
    }
    #endif
}
