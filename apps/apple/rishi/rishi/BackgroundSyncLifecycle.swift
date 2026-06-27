




























import Foundation
import RishiBilling
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

    
    
    
    private weak var dependencies: AppDependencies?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    

    
    
    
    
    
    
    
    static func shouldRunSilentPush(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    
    
    
    
    static func shouldRunBGTask(autoSync: Bool) -> Bool {
        shouldRunAutoSync(autoSync)
    }

    

    
    
    
    
    
    
    private func resolveServices() async -> BootstrappedServices? {
        guard let deps = dependencies else { return nil }
        if deps.services == nil {
            await deps.bootstrap()
        }
        return deps.services
    }

    

    
    
    
    
    
    
    
    
    
    
    
    func registerSynchronously() {
        #if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
        let processing = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.processingIdentifier,
            using: nil
        ) { [weak self] task in
            
            
            
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        let refresh = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskCoordinator.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            
            Task { @MainActor in
                await self?.driveBGTask(task)
            }
        }
        Log.event("sync.bg.registered", level: .info, data: [
            "processing": String(processing),
            "refresh": String(refresh),
            "via": "BackgroundSyncLifecycle.registerSynchronously",
        ])

        
        
        
        
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
    
    
    
    
    
    
    func driveBGTask(_ task: BGTask) async {
        guard let services = await resolveServices() else {
            task.setTaskCompleted(success: false)
            return
        }
        
        
        
        
        
        
        guard Self.shouldRunBGTask(autoSync: services.readerDefaults.autoSync) else {
            task.setTaskCompleted(success: true)
            services.backgroundTaskCoordinator.scheduleAll()
            return
        }
        
        
        
        let runTask = Task { [engine = services.syncEngine] in
            let wave = await engine.runOnce()
            return wave.errors.isEmpty
        }
        task.expirationHandler = { runTask.cancel() }
        let ok =  await runTask.value
        task.setTaskCompleted(success: ok)
        services.backgroundTaskCoordinator.scheduleAll()
    }
    #endif

    

    
    
    
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
            
        }
    }

    

    #if canImport(UIKit)
    
    
    
    
    
    
    
    
    func handleSilentPush(
        _ userInfo: [AnyHashable: Any],
        completion: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) async {
        guard let services = await resolveServices() else {
            completion(.noData)
            return
        }
        
        
        
        
        
        
        
        
        let isEntitlementChange = (userInfo["rishi"] as? [String: Any])?["kind"] as? String == "entitlement.changed"
        if !isEntitlementChange,
           !Self.shouldRunSilentPush(autoSync: services.readerDefaults.autoSync) {
            completion(.noData)
            return
        }
//        let entitlementService = services.entitlementService
        SilentPushHandler.handle(
            userInfo,
            engine: services.syncEngine,
       //     onEntitlementChanged: { await entitlementService.refresh() },
            completion: completion
        )
    }
    #endif
}
