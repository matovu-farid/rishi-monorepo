import Foundation
import RishiBilling
import RishiCore

extension AppDependencies {

    var entitlementService: EntitlementService { services!.entitlementService }
    var entitlementSnapshotStore: EntitlementSnapshotStore { services!.entitlementSnapshotStore }
    var entitlementRefreshCoordinator: EntitlementRefreshCoordinator {
        services!.entitlementRefreshCoordinator
    }
    var entitlementReconciler: EntitlementReconciler { services!.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.workerReceiptVerifier }

    /// Clear cached entitlement state for the outgoing account. Callable from
    /// any sign-out host before `CurrentUserBox.signout()`.
    func clearEntitlementState(for userId: String?) async {
        await entitlementService.clearSnapshotCache(for: userId)
        await entitlementService.clearCache()
        await MainActor.run {
            entitlementReconciler.reset()
        }
    }

    /// Full sign-out sequence: clear entitlement caches, then reset auth UI state.
    @MainActor
    func performSignOut(currentUserBox: CurrentUserBox) async {
        let outgoing = try? Keychain.load(.userId)
        await clearEntitlementState(for: outgoing)
        currentUserBox.signout()
    }
}
