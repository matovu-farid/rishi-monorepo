import Foundation

actor SharedSessionProgressStore {
    private let defaults: UserDefaults
    private let suiteName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.suiteName = "org.fidexa.rishi.shared-reading.\(accountId)"
        self.defaults = UserDefaults(suiteName: suiteName) ?? defaults
    }

    func saveIfNewer(_ progress: SharedReadingProgress) throws {
        let key = "progress.\(progress.sessionId)"
        if let data = defaults.data(forKey: key), let existing = try? decoder.decode(SharedReadingProgress.self, from: data), existing.sequence >= progress.sequence { return }
        defaults.set(try encoder.encode(progress), forKey: key)
    }

    func load(sessionId: String) throws -> SharedReadingProgress? {
        guard let data = defaults.data(forKey: "progress.\(sessionId)") else { return nil }
        return try decoder.decode(SharedReadingProgress.self, from: data)
    }

    func clear() { defaults.removePersistentDomain(forName: suiteName) }

}
