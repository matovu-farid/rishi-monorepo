import Foundation

actor ActiveReadingSessionStore {
    private let defaults: UserDefaults
    private let key = "active-reading-sessions"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.defaults = UserDefaults(suiteName: "org.fidexa.rishi.shared-reading.\(accountId)") ?? defaults
    }

    func save(_ sessions: [SharedReadingSessionSummary]) throws { defaults.set(try encoder.encode(sessions), forKey: key) }
    func load() throws -> [SharedReadingSessionSummary] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try decoder.decode([SharedReadingSessionSummary].self, from: data)
    }
    func clear() { defaults.removeObject(forKey: key) }
}
