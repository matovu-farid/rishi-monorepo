import Foundation

/// A restore can commit an earlier verified entitlement before a later one
/// fails. Both user-facing hosts refresh the same original account afterward,
/// then retain the original outcome/error for their own guarded presentation.
@available(iOS 18.4, macOS 15.4, *)
func restoreAndRefresh(restoreService: RestoreService,
                       refreshCoordinator: EntitlementRefreshCoordinator,
                       credentialContext: CredentialRequestContext) async throws -> RestoreOutcome {
    let original: Result<RestoreOutcome, Error>
    do { original = .success(try await restoreService.restore(credentialContext: credentialContext)) }
    catch { original = .failure(error) }
    _ = await refreshCoordinator.refreshIfSignedIn(reason: .foreground, credentialContext: credentialContext)
    return try original.get()
}
