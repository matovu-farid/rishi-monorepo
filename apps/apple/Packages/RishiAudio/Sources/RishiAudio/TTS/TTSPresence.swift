import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared persistence contract for the read-aloud presence surfaces.
///
/// The app writes the current TTS snapshot here so WidgetKit and Live
/// Activity rendering can read a single source of truth from the shared app
/// group.
public enum TTSPresenceEnvironment {
    public static let appGroupIdentifier = "group.org.fidexa.rishi"
    public static let snapshotKey = "tts.presence.snapshot"
    public static let widgetKind = "org.fidexa.rishi.tts.presence"
}

/// Serialisable, cross-process view of the current read-aloud session.
public struct TTSPresenceSnapshot: Codable, Sendable, Hashable {
    public let sessionID: String
    public let bookID: String
    public let bookTitle: String
    public let bookAuthor: String?
    public let status: TTSStatus
    public let currentPassageID: String?
    public let currentPassageIndex: Int?
    public let voice: String
    public let model: String
    public let speed: Double
    public let elapsed: TimeInterval
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case bookID
        case bookTitle
        case bookAuthor
        case status
        case currentPassageID
        case currentPassageIndex
        case voice
        case model
        case speed
        case elapsed
        case updatedAt
    }

    public init(
        sessionID: String,
        bookID: String,
        bookTitle: String,
        bookAuthor: String?,
        status: TTSStatus,
        currentPassageID: String?,
        currentPassageIndex: Int?,
        voice: String,
        model: String = TTSModelCatalog.defaultModel,
        speed: Double,
        elapsed: TimeInterval,
        updatedAt: Date = .init()
    ) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.status = status
        self.currentPassageID = currentPassageID
        self.currentPassageIndex = currentPassageIndex
        self.voice = voice
        self.model = model
        self.speed = speed
        self.elapsed = elapsed
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.bookID = try container.decode(String.self, forKey: .bookID)
        self.bookTitle = try container.decode(String.self, forKey: .bookTitle)
        self.bookAuthor = try container.decodeIfPresent(String.self, forKey: .bookAuthor)
        self.status = try container.decode(TTSStatus.self, forKey: .status)
        self.currentPassageID = try container.decodeIfPresent(String.self, forKey: .currentPassageID)
        self.currentPassageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPassageIndex)
        self.voice = try container.decode(String.self, forKey: .voice)
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? TTSModelCatalog.defaultModel
        self.speed = try container.decode(Double.self, forKey: .speed)
        self.elapsed = try container.decode(TimeInterval.self, forKey: .elapsed)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(bookID, forKey: .bookID)
        try container.encode(bookTitle, forKey: .bookTitle)
        try container.encodeIfPresent(bookAuthor, forKey: .bookAuthor)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(currentPassageID, forKey: .currentPassageID)
        try container.encodeIfPresent(currentPassageIndex, forKey: .currentPassageIndex)
        try container.encode(voice, forKey: .voice)
        try container.encode(model, forKey: .model)
        try container.encode(speed, forKey: .speed)
        try container.encode(elapsed, forKey: .elapsed)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var isActive: Bool {
        status == .loading || status == .playing || status == .paused
    }

    public var statusLabel: String {
        switch status {
        case .idle: return "Ready"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    public var subtitle: String {
        bookAuthor?.isEmpty == false ? bookAuthor! : "Unknown author"
    }

    public var passageLabel: String? {
        currentPassageIndex.map { "Paragraph \($0 + 1)" }
    }
}

/// Cross-process persistence seam for the TTS widget / Live Activity.
public protocol TTSPresenceStore: Sendable {
    func read() -> TTSPresenceSnapshot?
    func write(_ snapshot: TTSPresenceSnapshot)
    func clear()
}

/// Shared app-group backed store for read-aloud presence.
public final class UserDefaultsTTSPresenceStore: TTSPresenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(groupIdentifier: String = TTSPresenceEnvironment.appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: groupIdentifier) else {
            preconditionFailure("Unable to open app group defaults: \(groupIdentifier)")
        }
        self.defaults = defaults
    }

    public func read() -> TTSPresenceSnapshot? {
        lock.withLock {
            guard let data = defaults.data(forKey: TTSPresenceEnvironment.snapshotKey) else {
                return nil
            }
            return try? JSONDecoder().decode(TTSPresenceSnapshot.self, from: data)
        }
    }

    public func write(_ snapshot: TTSPresenceSnapshot) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: TTSPresenceEnvironment.snapshotKey)
        }
    }

    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: TTSPresenceEnvironment.snapshotKey)
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
/// ActivityKit payload used by the Live Activity and Dynamic Island.
public struct TTSPresenceAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var snapshot: TTSPresenceSnapshot

        public init(snapshot: TTSPresenceSnapshot) {
            self.snapshot = snapshot
        }
    }

    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
#endif
