import Foundation

/// UserDefaults-backed, account-scoped consent store.
public actor UserDefaultsDataUseConsentStore: CredentialDataUseConsentStore {
    public static let keyPrefix = "dataUseConsent."

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentUserID: String?
    private let credentialAuthority: SessionCredentialAuthority?
    private var boundLease: CredentialLease?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        credentialAuthority = nil
    }

    init(defaults: UserDefaults, credentialAuthority: SessionCredentialAuthority) {
        self.defaults = defaults
        self.credentialAuthority = credentialAuthority
    }

    public static func key(for userID: String) -> String {
        "\(keyPrefix)\(userID)"
    }

    public func setCurrentUser(_ userID: String?) async {
        guard credentialAuthority == nil else { return }
        currentUserID = userID.flatMap { Self.isAccountIdentifier($0) ? $0 : nil }
    }

    public func record(for userID: String) async -> ConsentRecord? {
        guard credentialAuthority == nil else { return nil }
        return readRecord(for: userID)
    }

    private func readRecord(for userID: String) -> ConsentRecord? {
        guard isCurrentUser(userID) else {
            return nil
        }

        guard let data = defaults.data(forKey: Self.key(for: userID)),
              let record = try? decoder.decode(ConsentRecord.self, from: data),
              record.version == DataUseConsent.currentVersion else {
            return nil
        }

        return record
    }

    public func grant(for userID: String) async {
        guard credentialAuthority == nil else { return }
        writeRecord(for: userID)
    }

    private func writeRecord(for userID: String) {
        guard isCurrentUser(userID) else { return }

        let record = ConsentRecord(
            version: DataUseConsent.currentVersion,
            timestamp: Date()
        )
        guard let data = try? encoder.encode(record) else { return }

        defaults.set(data, forKey: Self.key(for: userID))
    }

    public func revoke(for userID: String) async {
        guard credentialAuthority == nil else { return }
        guard isCurrentUser(userID) else { return }

        defaults.removeObject(forKey: Self.key(for: userID))
    }

    public func clearCurrentUser() async {
        guard credentialAuthority == nil else { return }
        currentUserID = nil
    }

    public func isCurrent(for userID: String) async -> Bool {
        guard credentialAuthority == nil else { return false }
        guard isCurrentUser(userID) else {
            return false
        }

        return await record(for: userID) != nil
    }

    func bind(to lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        return credentialAuthority.performIfCurrent(lease) {
            boundLease = lease
            currentUserID = DerivedUserID.from(lease.rawUserID).uuidString
        }
    }

    func record(for lease: CredentialLease) -> ConsentRecord? {
        guard let credentialAuthority else { return nil }
        var result: ConsentRecord?
        _ = credentialAuthority.performIfCurrent(lease) {
            if boundLease == lease { result = readRecord(for: DerivedUserID.from(lease.rawUserID).uuidString) }
        }
        return result
    }

    func grant(for lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        var applied = false
        _ = credentialAuthority.performIfCurrent(lease) {
            guard boundLease == lease else { return }
            writeRecord(for: DerivedUserID.from(lease.rawUserID).uuidString)
            applied = true
        }
        return applied
    }

    func revoke(for lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        var applied = false
        _ = credentialAuthority.performIfCurrent(lease) {
            guard boundLease == lease else { return }
            defaults.removeObject(forKey: Self.key(for: DerivedUserID.from(lease.rawUserID).uuidString))
            applied = true
        }
        return applied
    }

    func clear(for transition: CredentialTransition) -> Bool {
        guard let credentialAuthority else { return false }
        return credentialAuthority.performIfCurrent(transition) {
            if case .loaded(let outgoing) = transition.outgoing {
                defaults.removeObject(forKey: Self.key(for: DerivedUserID.from(outgoing.lease.rawUserID).uuidString))
            }
            currentUserID = nil
            boundLease = nil
        }
    }

    private func isCurrentUser(_ userID: String) -> Bool {
        Self.isAccountIdentifier(userID) && currentUserID == userID
    }

    private static func isAccountIdentifier(_ userID: String) -> Bool {
        !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Actor-backed store for tests and previews.
public actor InMemoryDataUseConsentStore: CredentialDataUseConsentStore {
    private var records: [String: ConsentRecord] = [:]
    private var currentUserID: String?
    private let credentialAuthority: SessionCredentialAuthority?
    private var boundLease: CredentialLease?

    public init() { credentialAuthority = nil }

    init(credentialAuthority: SessionCredentialAuthority) { self.credentialAuthority = credentialAuthority }

    public func setCurrentUser(_ userID: String?) async {
        guard credentialAuthority == nil else { return }
        currentUserID = userID.flatMap { Self.isAccountIdentifier($0) ? $0 : nil }
    }

    public func record(for userID: String) async -> ConsentRecord? {
        guard credentialAuthority == nil else { return nil }
        return readRecord(for: userID)
    }

    private func readRecord(for userID: String) -> ConsentRecord? {
        guard isCurrentUser(userID) else {
            return nil
        }
        guard let record = records[userID], record.version == DataUseConsent.currentVersion else {
            return nil
        }
        return record
    }

    public func grant(for userID: String) async {
        guard credentialAuthority == nil else { return }
        writeRecord(for: userID)
    }

    private func writeRecord(for userID: String) {
        guard isCurrentUser(userID) else { return }
        let record = ConsentRecord(version: DataUseConsent.currentVersion, timestamp: Date())
        records[userID] = record
    }

    public func revoke(for userID: String) async {
        guard credentialAuthority == nil else { return }
        guard isCurrentUser(userID) else { return }
        records.removeValue(forKey: userID)
    }

    public func clearCurrentUser() async {
        guard credentialAuthority == nil else { return }
        currentUserID = nil
    }

    public func isCurrent(for userID: String) async -> Bool {
        guard credentialAuthority == nil else { return false }
        guard isCurrentUser(userID) else { return false }
        return await record(for: userID) != nil
    }

    func bind(to lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        return credentialAuthority.performIfCurrent(lease) {
            boundLease = lease
            currentUserID = DerivedUserID.from(lease.rawUserID).uuidString
        }
    }

    func record(for lease: CredentialLease) -> ConsentRecord? {
        guard let credentialAuthority else { return nil }
        var result: ConsentRecord?
        _ = credentialAuthority.performIfCurrent(lease) {
            if boundLease == lease { result = readRecord(for: DerivedUserID.from(lease.rawUserID).uuidString) }
        }
        return result
    }

    func grant(for lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        var applied = false
        _ = credentialAuthority.performIfCurrent(lease) {
            guard boundLease == lease else { return }
            writeRecord(for: DerivedUserID.from(lease.rawUserID).uuidString)
            applied = true
        }
        return applied
    }

    func revoke(for lease: CredentialLease) -> Bool {
        guard let credentialAuthority else { return false }
        var applied = false
        _ = credentialAuthority.performIfCurrent(lease) {
            guard boundLease == lease else { return }
            records.removeValue(forKey: DerivedUserID.from(lease.rawUserID).uuidString)
            applied = true
        }
        return applied
    }

    func clear(for transition: CredentialTransition) -> Bool {
        guard let credentialAuthority else { return false }
        return credentialAuthority.performIfCurrent(transition) {
            if case .loaded(let outgoing) = transition.outgoing {
                records.removeValue(forKey: DerivedUserID.from(outgoing.lease.rawUserID).uuidString)
            }
            currentUserID = nil
            boundLease = nil
        }
    }

    private func isCurrentUser(_ userID: String) -> Bool {
        Self.isAccountIdentifier(userID) && currentUserID == userID
    }

    private static func isAccountIdentifier(_ userID: String) -> Bool {
        !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Bridges the account-scoped store to the shared Worker request contract.
/// No account or no current record means no header, so callers fail closed.
public struct AccountDataUseConsentProvider: WorkerDataUseConsentProvider {
    private enum Source: Sendable {
        case legacy(any DataUseConsentStore, @Sendable () async -> String?)
        case credential(any CredentialDataUseConsentStore, SessionCredentialAuthority)
    }
    private let source: Source

    public init(
        store: any DataUseConsentStore,
        userIDProvider: @escaping @Sendable () async -> String?
    ) {
        source = .legacy(store, userIDProvider)
    }

    init(store: any CredentialDataUseConsentStore, credentialAuthority: SessionCredentialAuthority) {
        source = .credential(store, credentialAuthority)
    }

    public func hasCurrentDataUseConsent() async -> Bool {
        switch source {
        case .legacy(let store, let userIDProvider):
            guard let userID = await userIDProvider() else { return false }
            await store.setCurrentUser(userID)
            return await store.isCurrent(for: userID)
        case .credential(let store, let authority):
            guard let captured = try? authority.snapshot() else { return false }
            let record = await store.record(for: captured.lease)
            return record?.version == DataUseConsent.currentVersion && authority.isCurrent(captured.lease)
        }
    }
}
