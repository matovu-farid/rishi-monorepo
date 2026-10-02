import Foundation

actor PendingSessionInviteStore {
    static let anonymous = PendingSessionInviteStore(accountId: "anonymous")
    private let defaults: UserDefaults
    private let key = "pending-session-invite"

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.defaults = UserDefaults(suiteName: "org.fidexa.rishi.shared-reading.\(accountId)") ?? defaults
    }

    func save(token: String) { defaults.set(token, forKey: key) }
    func load() -> String? { defaults.string(forKey: key) }
    /// An older redemption must not erase a different link queued while its
    /// network request was in flight.
    @discardableResult
    func clear(token: String) -> Bool {
        guard defaults.string(forKey: key) == token else { return false }
        defaults.removeObject(forKey: key)
        return true
    }

    /// Explicit account teardown and test reset may clear the whole queue.
    /// Asynchronous redemption completion must use `clear(token:)` instead.
    func clear() { defaults.removeObject(forKey: key) }
}
