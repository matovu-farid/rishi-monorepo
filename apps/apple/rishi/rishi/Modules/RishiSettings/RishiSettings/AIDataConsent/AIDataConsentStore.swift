import Foundation

/// UserDefaults-backed, account-scoped consent store.
public actor UserDefaultsDataUseConsentStore: DataUseConsentStore {
    public static let keyPrefix = "dataUseConsent."

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentUserID: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(for userID: String) -> String {
        "\(keyPrefix)\(userID)"
    }

    public func setCurrentUser(_ userID: String?) async {
        currentUserID = userID.flatMap { Self.isAccountIdentifier($0) ? $0 : nil }
    }

    public func record(for userID: String) async -> ConsentRecord? {
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
        guard isCurrentUser(userID) else { return }

        let record = ConsentRecord(
            version: DataUseConsent.currentVersion,
            timestamp: Date()
        )
        guard let data = try? encoder.encode(record) else { return }

        defaults.set(data, forKey: Self.key(for: userID))
    }

    public func revoke(for userID: String) async {
        guard isCurrentUser(userID) else { return }

        defaults.removeObject(forKey: Self.key(for: userID))
    }

    public func clearCurrentUser() async {
        currentUserID = nil
    }

    public func isCurrent(for userID: String) async -> Bool {
        guard isCurrentUser(userID) else {
            return false
        }

        return await record(for: userID) != nil
    }

    private func isCurrentUser(_ userID: String) -> Bool {
        Self.isAccountIdentifier(userID) && currentUserID == userID
    }

    private static func isAccountIdentifier(_ userID: String) -> Bool {
        !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Actor-backed store for tests and previews.
public actor InMemoryDataUseConsentStore: DataUseConsentStore {
    private var records: [String: ConsentRecord] = [:]
    private var currentUserID: String?

    public init() {}

    public func setCurrentUser(_ userID: String?) async {
        currentUserID = userID.flatMap { Self.isAccountIdentifier($0) ? $0 : nil }
    }

    public func record(for userID: String) async -> ConsentRecord? {
        guard isCurrentUser(userID) else {
            return nil
        }
        guard let record = records[userID], record.version == DataUseConsent.currentVersion else {
            return nil
        }
        return record
    }

    public func grant(for userID: String) async {
        guard isCurrentUser(userID) else { return }
        let record = ConsentRecord(version: DataUseConsent.currentVersion, timestamp: Date())
        records[userID] = record
    }

    public func revoke(for userID: String) async {
        guard isCurrentUser(userID) else { return }
        records.removeValue(forKey: userID)
    }

    public func clearCurrentUser() async {
        currentUserID = nil
    }

    public func isCurrent(for userID: String) async -> Bool {
        guard isCurrentUser(userID) else { return false }
        return await record(for: userID) != nil
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
    private let store: any DataUseConsentStore
    private let userIDProvider: @Sendable () async -> String?

    public init(
        store: any DataUseConsentStore,
        userIDProvider: @escaping @Sendable () async -> String?
    ) {
        self.store = store
        self.userIDProvider = userIDProvider
    }

    public func hasCurrentDataUseConsent() async -> Bool {
        guard let userID = await userIDProvider() else { return false }
        await store.setCurrentUser(userID)
        return await store.isCurrent(for: userID)
    }
}
