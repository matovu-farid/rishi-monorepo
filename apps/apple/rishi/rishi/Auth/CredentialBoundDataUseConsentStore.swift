import Foundation

/// The existing settings/consent UI port is bound to its presented account.
/// String operations forward to the actual store's required lease admission;
/// a retained A view cannot adopt a later A installation or account B.
struct CredentialBoundDataUseConsentStore: DataUseConsentStore {
    let store: any CredentialDataUseConsentStore
    let authority: SessionCredentialAuthority
    let lease: CredentialLease

    private var userID: String { DerivedUserID.from(lease.rawUserID).uuidString }
    private func admits(_ requested: String?) -> Bool {
        requested == userID && authority.isCurrent(lease)
    }
    func setCurrentUser(_ requested: String?) async {
        guard admits(requested) else { return }
        _ = await store.bind(to: lease)
    }
    func record(for requested: String) async -> ConsentRecord? {
        guard admits(requested) else { return nil }
        let record = await store.record(for: lease)
        return admits(requested) ? record : nil
    }
    func grant(for requested: String) async {
        guard admits(requested) else { return }
        _ = await store.grant(for: lease)
    }
    func revoke(for requested: String) async {
        guard admits(requested) else { return }
        _ = await store.revoke(for: lease)
    }
    func isCurrent(for requested: String) async -> Bool {
        await record(for: requested) != nil
    }
    // No settings/consent host calls this account-transition operation.
    // The original app transaction alone can clear the actual bound identity.
    func clearCurrentUser() async {}
}
