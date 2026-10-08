import Foundation

extension AppDependencies {
    /// Called only by the original app retirement/deletion reservation.
    /// It may join sync and account work after the initiating request unwinds.
    func cleanupCredentialAccount(_ transaction: AccountChangeTransaction) async throws {
        guard isCurrentCredentialAccountChange(transaction),
              let transition = transaction.credentialTransition else { throw CredentialAuthenticationFailure.accountChanged }
        await bootstrap()
        guard isCurrentCredentialAccountChange(transaction), let services else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        #if DEBUG
        if RishiE2EConfiguration.isReset { try await services.purgeAccountLocally(transaction: transaction, authority: credentialAuthority) }
        #endif
        let transfers = services.library.sharePackageService
        await transfers.beginAccountSwitchAndWait()
        do {
            await services.voice.presenter.requestEnd()
            await services.sync.engine.resetForAccountSwitch()
            guard isCurrentCredentialAccountChange(transaction) else { throw CredentialAuthenticationFailure.accountChanged }
            if let owner = transaction.outgoingAccountID {
                await PendingShareStore.shared.clearTransientState(for: owner)
            }
            guard await services.dataUseConsentStore.clear(for: transition),
                  await services.billing.entitlementService.clearCache(in: transition) else {
                throw CredentialAuthenticationFailure.accountChanged
            }
            guard credentialAuthority.performIfCurrent(transition, mutation: {
                if let lease = transaction.outgoingNormalCredentialLease {
                    services.billing.customerEntitlements.clearAccountProjection(lease: lease)
                    services.billing.store.clearAccountProjection(lease: lease)
                }
                services.billing.entitlementReconciler.reset()
                GoogleSignInCoordinator.signOut()
            }) else { throw CredentialAuthenticationFailure.accountChanged }
            if let metadata = services.sync.metadataStore as? SwiftDataSyncMetadataStore { try await metadata.resetAll() }
            guard isCurrentCredentialAccountChange(transaction) else { throw CredentialAuthenticationFailure.accountChanged }
        } catch {
            await transfers.endAccountSwitch()
            throw error
        }
        await transfers.endAccountSwitch()
    }

    /// Server DELETE, purge, and sign-out retain one transaction and its
    /// admitted outgoing credential rather than selecting the ambient account.
    func accountDeletionCoordinator(
        snapshot: CredentialSnapshot, accountIdentity: LibraryAccountIdentity,
        publishSignedOut: @escaping @MainActor @Sendable () -> Void
    ) throws -> AccountDeletionCoordinator {
        _ = try credentialAuthority.snapshot(for: .normal(snapshot.lease))
        guard activeAccountIdentity == accountIdentity,
              accountIdentity.userID == DerivedUserID.from(snapshot.lease.rawUserID),
              let services else { throw CredentialAuthenticationFailure.accountChanged }
        return AccountDeletionCoordinator(
            admittedDeleteServer: { admission in
                _ = try await services.workerClient.send(DeleteUserEndpoint(), credentialContext: admission.requestContext)
            }, purgeLocal: { [self] transaction in
                guard isCurrentCredentialAccountChange(transaction) else { throw CredentialAuthenticationFailure.accountChanged }
                try await services.purgeAccountLocally(transaction: transaction, authority: credentialAuthority)
            }, restoreOwner: { [self] transaction in
                try await restoreCredentialOwnerAfterDeletionFailure(transaction)
            }, isCurrent: { [self] transaction in isCurrentCredentialAccountChange(transaction) },
            beginCleanup: { [self] transaction in beginAccountCleanup(transaction) },
            endCleanup: { [self] transaction in endAccountCleanup(transaction) },
            signOut: { [self] transaction in
                try await cleanupCredentialAccount(transaction)
                try clearCredentialSessionAndIdentity(in: transaction)
                guard let transition = transaction.credentialTransition,
                      credentialAuthority.performIfCurrent(transition, mutation: publishSignedOut) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
            }, beginChange: { [self] in
                _ = try credentialAuthority.snapshot(for: .normal(snapshot.lease))
                guard activeAccountIdentity == accountIdentity else { throw CredentialAuthenticationFailure.accountChanged }
                return try beginAccountChange(expectedCredentialTicket: snapshot.ticket)
            })
    }

    // Compatibility hosts must use the app-owned retirement and UI projection.
    @MainActor
    func performSignOut(currentUserBox: CurrentUserBox) async {
        guard let adapter = credentialAuthenticationAdapter else { return }
        do { try adapter.retireCurrentAccount(expected: credentialAuthority.attemptTicket(), into: currentUserBox) }
        catch { Log.error("auth.signout.admission.failed", error: error) }
    }
}

extension BootstrappedServices {
    /// The caller holds the actual app cleanup reservation throughout this
    /// ordered destructive purge. Its authority transition is never refreshed.
    @MainActor
    func purgeAccountLocally(transaction: AccountChangeTransaction, authority: SessionCredentialAuthority) async throws {
        guard let transition = transaction.credentialTransition, authority.isCurrent(transition) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        var cleanupError: Error?
        if let owner = transaction.outgoingAccountID, let generation = transaction.outgoingAccountGeneration {
            _ = library.bookImportLifecycle.fenceAccount(ownerID: owner, generation: generation)
            let permit = AccountMutationPermit(ownerID: owner, accountGeneration: generation)
            library.scopedMutationStore.closeAdmission(for: permit)
            await systemIntegration.spotlight.clearForAccountDeletion()
            await audio.playbackOwner.stopForAccountChange()
            await voice.presenter.requestEnd()
            await sharedReadingSessionRegistry.drain(accountID: owner)
            await sync.engine.resetForAccountSwitch()
            do { try await library.scopedMutationStore.revoke(permit) } catch { cleanupError = error }
            await library.bookImportLifecycle.drainAccount(owner, generation: generation)
            do { try library.bookFileStorage.purgeAll() } catch { cleanupError = cleanupError ?? error }
            do { try await library.dbStore.purgeAll() } catch { cleanupError = cleanupError ?? error }
            await audio.ttsSettingsStore.remove(userId: owner)
            await onboarding.trialState.remove(userId: owner)
        }
        if let metadata = sync.metadataStore as? SwiftDataSyncMetadataStore {
            do { try await metadata.resetAll() } catch { cleanupError = cleanupError ?? error }
        }
        guard await dataUseConsentStore.clear(for: transition),
              await billing.entitlementService.clearCache(in: transition),
              authority.performIfCurrent(transition, mutation: { billing.entitlementReconciler.reset() }) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        if let cleanupError { throw cleanupError }
    }
}
