import Foundation



extension AppDependencies {

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
        // Consume a preflight transaction when the caller created one before
        // entering a Task; direct callers still receive the same fence here.
        let transaction = pendingAccountChange ?? (try? beginAccountChange())
        pendingAccountChange = nil
        await transaction?.drain.value
        let hadCurrentAccount = userIdBox.value != nil
        if hadCurrentAccount {
            userIdBox.value = nil
            notifyCarPlayAccountChange()
        }
        GoogleSignInCoordinator.signOut()
        let outgoing = try? Keychain.load(.userId)
        await services?.dataUseConsentStore.clearCurrentUser()
        await clearEntitlementState(for: outgoing)
        await services!.sync.engine.resetForAccountSwitch()
        Keychain.delete(.accessToken)
        Keychain.delete(.refreshToken)
        Keychain.delete(.userId)
        do {
            try await KeychainSessionStore().delete()
        } catch {
            Log.error("auth.signout.session-delete.failed", error: error)
        }
        _ = await replaceUserId(
            nil,
            allowDeferredCleanup: true,
            forceTransition: hadCurrentAccount,
            skipAccountFence: true
        )
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
