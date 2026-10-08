import Foundation




#if canImport(UIKit)
    import UIKit
#endif
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
    import BackgroundTasks
#endif

private final class BackgroundImportPauseTask: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    private var completed = false
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Task<Void, Never>?, Never>] = []

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        triggered = true
        return true
    }

    func store(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: task) }
    }

    func finishAndWaitForTaskRegistration() async -> Task<Void, Never>? {
        await withCheckedContinuation { continuation in
            lock.lock()
            completed = true
            if !triggered {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if let task {
                lock.unlock()
                continuation.resume(returning: task)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

@MainActor
final class BackgroundSyncLifecycle {

    private struct RecoveryKey: Hashable {
        let ownerID: UUID
        let generation: UInt64
    }

    private weak var dependencies: AppDependencies?
    private var userIdBox: UserIdBox
    private var pendingDeviceToken: Data?
    private let credentialRegistrar: APNsDeviceRegistrar?
    private var activeRecoveries = Set<RecoveryKey>()
    private var completedRecoveries = Set<RecoveryKey>()

    init(dependencies: AppDependencies, userIdBox: UserIdBox) {
        self.dependencies = dependencies
        self.userIdBox = userIdBox
        credentialRegistrar = nil
    }

    /// Explicit actual-registrar injection for an inactive scoped lifecycle.
    init(dependencies: AppDependencies, userIdBox: UserIdBox, credentialRegistrar: APNsDeviceRegistrar) {
        self.dependencies = dependencies
        self.userIdBox = userIdBox
        self.credentialRegistrar = credentialRegistrar
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
        guard userIdBox.value == userId,
              let services = deps.services else { return nil }
        let generation = deps.accountGeneration
        await recoverCurrentOwner(
            ownerID: userId,
            generation: generation,
            recovery: services.library.bookImportRecovery
        )
        guard userIdBox.value == userId, deps.accountGeneration == generation else { return nil }
        return services
    }

    /// Startup and background service resolution can race. Run owner recovery
    /// once for each authenticated account generation, retrying if recovery
    /// throws so a later service resolution can make progress.
    func recoverCurrentOwner(ownerID: UserID, generation: UInt64, recovery: BookImportRecovery) async {
        guard let deps = dependencies,
              userIdBox.value == ownerID,
              deps.accountGeneration == generation else { return }
        let key = RecoveryKey(ownerID: ownerID, generation: generation)
        guard !completedRecoveries.contains(key), !activeRecoveries.contains(key) else { return }
        activeRecoveries.insert(key)
        defer { activeRecoveries.remove(key) }
        do {
            _ = try await recovery.recover(ownerID: ownerID, generation: generation) { [weak self, weak deps] in
                guard let self, let deps else { return false }
                return self.userIdBox.value == ownerID && deps.accountGeneration == generation
            }
            guard userIdBox.value == ownerID, deps.accountGeneration == generation else { return }
            completedRecoveries.insert(key)
        } catch {
            Log.event("library.import.recovery.failed", level: .info, data: ["owner_id": ownerID.uuidString, "error": String(describing: error)])
        }
    }

    @MainActor
    static func pauseImportsIfCurrent(
        ownerID: UserID,
        generation: UInt64,
        currentOwnerID: UserID?,
        currentGeneration: UInt64,
        activationToken: BookImportActivationToken,
        pauseAccount: @Sendable (UserID, UInt64, BookImportActivationToken) async -> Void
    ) async {
        guard currentOwnerID == ownerID, currentGeneration == generation else { return }
        await pauseAccount(ownerID, generation, activationToken)
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

            let chapterIndexBookIDs = (try? await services.library.bookStore.books(for: userId))?.map(\.id) ?? []

            guard
                Self.shouldRunBGTask(autoSync: services.settings.readerDefaults.autoSync)
            else {
                task.setTaskCompleted(success: true)
                services.sync.backgroundTaskCoordinator.scheduleAll()
                return
            }

            let chapterIndexTask = Task {
                await services.sync.chapterIndexGenerationDispatcher.run(chapterIndexBookIDs)
            }
            let importCoordinator = services.library.bookMaterializationCoordinator
            let runTask = Task { [engine = services.sync.engine] in
                let wave = await engine.runOnce()
                return wave.errors.isEmpty
            }
            let generation = dependencies?.accountGeneration ?? 0
            let expirationPause = BackgroundImportPauseTask()
            task.expirationHandler = { [weak self] in
                guard expirationPause.begin() else { return }
                let activationToken = importCoordinator.fenceAccountForPause(ownerID: userId, generation: generation)
                runTask.cancel()
                chapterIndexTask.cancel()
                let pauseTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await Self.pauseImportsIfCurrent(
                        ownerID: userId,
                        generation: generation,
                        currentOwnerID: self.userIdBox.value,
                        currentGeneration: self.dependencies?.accountGeneration ?? 0,
                        activationToken: activationToken,
                        pauseAccount: { ownerID, generation, activationToken in
                            await importCoordinator.pauseAccount(ownerID: ownerID, generation: generation, activationToken: activationToken)
                        }
                    )
                }
                expirationPause.store(pauseTask)
            }
            let ok = await runTask.value
            await chapterIndexTask.value
            if let pauseTask = await expirationPause.finishAndWaitForTaskRegistration() {
                await pauseTask.value
            }
            task.setTaskCompleted(success: ok)
            services.sync.backgroundTaskCoordinator.scheduleAll()
        }
    #endif

    func registerDeviceToken(
        _ token: Data,
        platform: String,
        appVersion: String
    ) async {
        pendingDeviceToken = token
        guard let dependencies, let snapshot = try? dependencies.credentialAuthority.snapshot(),
              userIdBox.value == DerivedUserID.from(snapshot.lease.rawUserID) else { return }
        do {
            try await retryPendingDeviceTokenIfAvailable(platform: platform, appVersion: appVersion,
                                                        credentialContext: .normal(snapshot.lease))
        } catch { Log.error("sync.device.registration.failed", error: error) }
    }

    func retryPendingDeviceTokenIfAvailable(
        platform: String,
        appVersion: String
    ) async {
        guard let token = pendingDeviceToken else { return }
        await registerDeviceToken(token, platform: platform, appVersion: appVersion)
    }

    /// Auth retry retains its admitted context through service resolution and send.
    func retryPendingDeviceTokenIfAvailable(
        platform: String, appVersion: String, credentialContext: CredentialRequestContext
    ) async throws {
        guard case .normal(let lease) = credentialContext, let dependencies,
              dependencies.performCredentialMutation(lease, mutation: {}) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        guard let token = pendingDeviceToken else { return }
        let ownerID = DerivedUserID.from(lease.rawUserID)
        let registrar: APNsDeviceRegistrar
        if let credentialRegistrar { registrar = credentialRegistrar }
        else if let resolved = await resolveServices(userId: ownerID)?.sync.apnsDeviceRegistrar { registrar = resolved }
        else { throw CredentialAuthenticationFailure.accountChanged }
        try await registrar.register(token: token, platform: platform, appVersion: appVersion,
                                     credentialContext: credentialContext)
        guard dependencies.performCredentialMutation(lease, mutation: {
            if pendingDeviceToken == token { pendingDeviceToken = nil }
        }) else { throw CredentialAuthenticationFailure.accountChanged }
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
