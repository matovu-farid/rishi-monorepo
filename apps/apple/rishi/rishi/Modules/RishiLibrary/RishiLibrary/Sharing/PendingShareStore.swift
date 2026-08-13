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

    /// Retains account-bound redemption state across sign-out. A one-time
    /// token is claimed for the account that started redeeming it; unbinding
    /// it here would let the next account on the device consume that token.
    /// Progress IDs are also retained so a retry resumes the same local book.
    public func clearTransientState(for userID: UUID) {
        _ = userID
        state.tokenOwners = state.tokenOwners.filter { state.tokens.contains($0.key) }
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
