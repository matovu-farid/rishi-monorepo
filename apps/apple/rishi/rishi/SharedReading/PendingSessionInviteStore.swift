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
    func clear() { defaults.removeObject(forKey: key) }
}
