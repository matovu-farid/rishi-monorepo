import Foundation

public actor PendingShareStore {
    public static let shared = PendingShareStore()
    private struct State: Codable, Sendable {
        var tokens: [String] = []
        var tokenOwners: [String: String] = [:]
        var packageBookIDs: [String: String] = [:]
        var acceptedPackages: [String] = []
        var acceptedPackagesByUser: [String: [String]] = [:]
        var shareNotificationPending = false

        private enum CodingKeys: String, CodingKey {
            case tokens, tokenOwners, packageBookIDs, acceptedPackages, acceptedPackagesByUser, shareNotificationPending
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try container.decodeIfPresent([String].self, forKey: .tokens) ?? []
            tokenOwners = try container.decodeIfPresent([String: String].self, forKey: .tokenOwners) ?? [:]
            packageBookIDs = try container.decodeIfPresent([String: String].self, forKey: .packageBookIDs) ?? [:]
            acceptedPackages = try container.decodeIfPresent([String].self, forKey: .acceptedPackages) ?? []
            acceptedPackagesByUser = try container.decodeIfPresent([String: [String]].self, forKey: .acceptedPackagesByUser) ?? [:]
            shareNotificationPending = try container.decodeIfPresent(Bool.self, forKey: .shareNotificationPending) ?? false
        }
    }

    private let defaults: UserDefaults
    private let key: String
    private var state: State

    public init(
        defaults: UserDefaults = .standard,
        key: String = "rishi.pending-share-state"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    public func enqueue(token: String) {
        guard !token.isEmpty else { return }
        state.tokens.removeAll { $0 == token }
        state.tokens.append(token)
        if state.tokens.count > 20 {
            state.tokens.removeFirst(state.tokens.count - 20)
        }
        persist()
    }

    public func tokens() -> [String] { state.tokens }

    public func tokens(for userID: UUID) -> [String] {
        state.tokens.filter { token in
            guard let owner = state.tokenOwners[token] else { return true }
            return owner == userID.uuidString
        }
    }

    public func bindToken(_ token: String, to userID: UUID) {
        guard state.tokens.contains(token) else { return }
        state.tokenOwners[token] = userID.uuidString
        persist()
    }

    public func remove(token: String) {
        state.tokens.removeAll { $0 == token }
        state.tokenOwners[token] = nil
        persist()
    }

    public func enqueueAcceptedPackage(_ packageID: String) {
        guard !state.acceptedPackages.contains(packageID) else { return }
        state.acceptedPackages.append(packageID)
        persist()
    }

    public func enqueueAcceptedPackage(_ packageID: String, userID: UUID) {
        var packages = state.acceptedPackagesByUser[userID.uuidString] ?? []
        guard !packages.contains(packageID) else { return }
        packages.append(packageID)
        state.acceptedPackagesByUser[userID.uuidString] = packages
        persist()
    }

    public func acceptedPackageIDs() -> [String] { state.acceptedPackages }

    public func acceptedPackageIDs(for userID: UUID) -> [String] {
        state.acceptedPackagesByUser[userID.uuidString] ?? []
    }

    public func removeAcceptedPackage(_ packageID: String) {
        state.acceptedPackages.removeAll { $0 == packageID }
        for userID in Array(state.acceptedPackagesByUser.keys) {
            state.acceptedPackagesByUser[userID]?.removeAll { $0 == packageID }
        }
        state.packageBookIDs = state.packageBookIDs.filter { !$0.key.hasPrefix("\(packageID):") }
        persist()
    }

    public func removeAcceptedPackage(_ packageID: String, userID: UUID) {
        state.acceptedPackagesByUser[userID.uuidString]?.removeAll { $0 == packageID }
        state.packageBookIDs = state.packageBookIDs.filter { !$0.key.hasPrefix("\(packageID):") }
        persist()
    }

    public func bookID(packageID: String, itemID: String) -> UUID? {
        guard let raw = state.packageBookIDs["\(packageID):\(itemID)"] else { return nil }
        return UUID(uuidString: raw)
    }

    public func recordBookID(_ bookID: UUID, packageID: String, itemID: String) {
        state.packageBookIDs["\(packageID):\(itemID)"] = bookID.uuidString
        persist()
    }

    public func enqueueShareNotification() {
        state.shareNotificationPending = true
        persist()
    }

    public func consumeShareNotification() -> Bool {
        guard state.shareNotificationPending else { return false }
        state.shareNotificationPending = false
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
