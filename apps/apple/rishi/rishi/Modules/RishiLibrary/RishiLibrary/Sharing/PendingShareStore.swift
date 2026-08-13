import Foundation

public actor PendingShareStore {
    public static let shared = PendingShareStore()
    private struct State: Codable, Sendable {
        var tokens: [String] = []
        var tokenOwners: [String: String] = [:]
        var packageBookIDs: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case tokens, tokenOwners, packageBookIDs
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try container.decodeIfPresent([String].self, forKey: .tokens) ?? []
            tokenOwners = try container.decodeIfPresent([String: String].self, forKey: .tokenOwners) ?? [:]
            packageBookIDs = try container.decodeIfPresent([String: String].self, forKey: .packageBookIDs) ?? [:]
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

    /// Drops account-bound redemption state before sign-out. Tokens remain
    /// queued but are anonymous again; local package IDs are cleared so a
    /// later account cannot reuse a book identity from the previous account.
    public func clearTransientState(for userID: UUID) {
        let ownedTokens = state.tokenOwners.compactMap { token, owner in
            owner == userID.uuidString ? token : nil
        }
        for token in ownedTokens { state.tokenOwners[token] = nil }
        state.packageBookIDs.removeAll()
        persist()
    }

    public func remove(token: String) {
        state.tokens.removeAll { $0 == token }
        state.tokenOwners[token] = nil
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
