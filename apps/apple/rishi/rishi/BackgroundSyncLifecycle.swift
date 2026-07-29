import Foundation




#if canImport(UIKit)
    import UIKit
#endif
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
    import BackgroundTasks
#endif

@MainActor
final class BackgroundSyncLifecycle {

    private weak var dependencies: AppDependencies?
    private var userIdBox: UserIdBox
    private var pendingDeviceToken: Data?

    init(dependencies: AppDependencies, userIdBox: UserIdBox) {
        self.dependencies = dependencies
        self.userIdBox = userIdBox
    }

    static func shouldRunSilentPush(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    static func shouldRunBGTask(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    private func resolveServices(userId: UUID) async -> BootstrappedServices? {
        guard let deps = dependencies else { return nil }
        if deps.services == nil {
            await deps.bootstrap()
        }
        guard userIdBox.value == userId else { return nil }
        return deps.services
    }

    func registerSynchronously() {
        #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
            let registration = BackgroundTaskCoordinator.register(
                surface: BackgroundTaskCoordinator.SystemSurface()
            ) { [weak self] task in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    await self.driveBGTask(task)
                }
            }
            Log.event(
                "sync.bg.registered",
                level: .info,
                data: [
                    "processing": String(registration.processing),
                    "refresh": String(registration.refresh),
                    "via": "BackgroundSyncLifecycle.registerSynchronously",
                ]
            )

            BackgroundTaskCoordinator.scheduleAll(
                surface: BackgroundTaskCoordinator.SystemSurface(),
                config: SyncEngineConfig(backgroundRefreshInterval: 60 * 60)
            )
            Log.event("sync.bg.scheduled", level: .info)
        #endif
    }

    #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))

        func driveBGTask(_ task: BGTask) async {
            guard let userId = userIdBox.value else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let services = await resolveServices(userId: userId) else {
                task.setTaskCompleted(success: false)
                return
            }

            guard
                Self.shouldRunBGTask(autoSync: services.settings.readerDefaults.autoSync)
            else {
                task.setTaskCompleted(success: true)
                services.sync.backgroundTaskCoordinator.scheduleAll()
                return
            }

            let runTask = Task { [engine = services.sync.engine] in
                let wave = await engine.runOnce()
                return wave.errors.isEmpty
            }
            task.expirationHandler = { runTask.cancel() }
            let ok = await runTask.value
            task.setTaskCompleted(success: ok)
            services.sync.backgroundTaskCoordinator.scheduleAll()
        }
    #endif

    func registerDeviceToken(
        _ token: Data,
        platform: String,
        appVersion: String
    ) async {
        guard let userId = userIdBox.value else {
            pendingDeviceToken = token
            return
        }
        guard let registrar = await resolveServices(userId: userId)?.sync.apnsDeviceRegistrar
        else { return }
        do {
            try await registrar.register(
                token: token,
                platform: platform,
                appVersion: appVersion
            )
            pendingDeviceToken = nil
        } catch {

        }
    }

    func retryPendingDeviceTokenIfAvailable(
        platform: String,
        appVersion: String
    ) async {
        guard let token = pendingDeviceToken else { return }
        await registerDeviceToken(token, platform: platform, appVersion: appVersion)
    }

    #if canImport(UIKit)

        func handleSilentPush(
            _ userInfo: [AnyHashable: Any],
            completion: @escaping @Sendable (UIBackgroundFetchResult) -> Void
        ) async {
            guard let userId = userIdBox.value else {
                completion(.noData)
                return
            }
            guard let services = await resolveServices(userId: userId) else {
                completion(.noData)
                return
            }

            let isEntitlementChange =
                (userInfo["rishi"] as? [String: Any])?["kind"] as? String
                == "entitlement.changed"
            if !isEntitlementChange,
                !Self.shouldRunSilentPush(
                    autoSync: services.settings.readerDefaults.autoSync
                )
            {
                completion(.noData)
                return
            }
            //        let entitlementService = services.billing.entitlementService
            SilentPushHandler.handle(
                userInfo,
                engine: services.sync.engine,
                //     onEntitlementChanged: { await entitlementService.refresh() },
                completion: completion
            )
        }
    #endif
}
