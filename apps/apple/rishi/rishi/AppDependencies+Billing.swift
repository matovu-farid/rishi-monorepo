import Foundation



extension AppDependencies {

    var entitlementService: EntitlementService { services!.billing.entitlementService }
    var entitlementSnapshotStore: EntitlementSnapshotStore { services!.billing.entitlementSnapshotStore }
    var entitlementRefreshCoordinator: EntitlementRefreshCoordinator {
        services!.billing.entitlementRefreshCoordinator
    }
    var entitlementReconciler: EntitlementReconciler { services!.billing.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.billing.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.billing.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.billing.workerReceiptVerifier }

    /// Clear cached entitlement state for the outgoing account. Callable from
    /// any sign-out host before `CurrentUserBox.signout()`.
    func clearEntitlementState(for userId: String?) async {
        await services!.billing.entitlementService.clearSnapshotCache(for: userId)
        await services!.billing.entitlementService.clearCache()
        await MainActor.run {
            services!.billing.entitlementReconciler.reset()
        }
    }

    /// Full sign-out sequence: clear entitlement caches, then reset auth UI state.
    @MainActor
    func performSignOut(currentUserBox: CurrentUserBox) async {
        let outgoing = try? Keychain.load(.userId)
        await clearEntitlementState(for: outgoing)
        await services!.sync.engine.resetForAccountSwitch()
        userIdBox.value = nil
        if let metadataStore = services?.sync.metadataStore as? SwiftDataSyncMetadataStore {
            do {
                try await metadataStore.resetAll()
            } catch {
                Log.error("sync.signout.metadata-reset.failed", error: error)
            }
        }
        currentUserBox.signout()
    }
}
