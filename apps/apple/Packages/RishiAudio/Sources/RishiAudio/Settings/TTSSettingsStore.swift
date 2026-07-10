import Foundation
import RishiCore
import RishiLogging

/// Per-user TTS settings persistence (TTS-07). The Picker UI in plan 08-06
/// updates settings; TTSEngine (plan 08-04) reads them when constructing
/// the next worker speech request body.
public protocol TTSSettingsStore: Sendable {
    func load(userId: UserID) async -> TTSSettings
    func save(_ settings: TTSSettings, userId: UserID) async
}

// MARK: - UserDefaults impl

/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which
/// is non-Sendable under Swift 6 strict concurrency despite documented
/// thread-safe scalar accessors.
public final class UserDefaultsTTSSettingsStore: TTSSettingsStore, @unchecked Sendable {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(userId: UserID) async -> TTSSettings {
        let key = Self.key(for: userId)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(TTSSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save(_ settings: TTSSettings, userId: UserID) async {
        let key = Self.key(for: userId)
        guard let data = try? JSONEncoder().encode(settings) else {
            Log.event("tts.settings.encode_failed", level: .error, data: ["userId": userId.uuidString])
            return
        }
        defaults.set(data, forKey: key)
        Log.event("tts.settings.saved", level: .info, data: [
            "userId": userId.uuidString,
            "voice": settings.voice,
            "model": settings.model,
            "speed": String(format: "%.2f", settings.speed),
        ])
    }

    static func key(for userId: UserID) -> String {
        "tts.settings.\(userId.uuidString)"
    }
}

// MARK: - In-memory impl

public actor InMemoryTTSSettingsStore: TTSSettingsStore {
    private var values: [UserID: TTSSettings] = [:]

    public init() {}

    public func load(userId: UserID) async -> TTSSettings {
        values[userId] ?? .default
    }

    public func save(_ settings: TTSSettings, userId: UserID) async {
        values[userId] = settings
    }
}
