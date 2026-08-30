import Foundation

enum SharedReadingSessionStatus: String, Codable, Sendable, Equatable {
    case waiting
    case active
    case ended
}

enum SharedReadingBookFormat: String, Codable, Sendable, Equatable {
    case epub
    case pdf
}

struct SharedReadingBook: Codable, Sendable, Equatable {
    let bookId: String
    let contentHash: String
    let format: SharedReadingBookFormat
    let fileSize: Int64
    let downloadURL: URL?
}

struct SharedReadingParticipant: Codable, Sendable, Equatable, Identifiable {
    let userId: String
    let displayName: String
    let avatarURL: URL?
    let joinedAt: Date
    let bookReady: Bool
    let connectionState: String
    let isController: Bool

    var id: String { userId }

    private enum CodingKeys: String, CodingKey {
        case userId, profile, displayName, avatarURL, avatarUrl, joinedAt, bookReady, connectionState, isController
    }

    private struct Profile: Codable {
        let displayName: String
        let avatarUrl: URL?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        if let profile = try? container.decode(Profile.self, forKey: .profile) {
            displayName = profile.displayName
            avatarURL = profile.avatarUrl
        } else {
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? userId
            avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
                ?? container.decodeIfPresent(URL.self, forKey: .avatarUrl)
        }
        if let millis = try? container.decode(Int64.self, forKey: .joinedAt) {
            joinedAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
        } else if let date = try? container.decode(Date.self, forKey: .joinedAt) {
            joinedAt = date
        } else {
            joinedAt = .distantPast
        }
        bookReady = try container.decodeIfPresent(Bool.self, forKey: .bookReady) ?? false
        connectionState = try container.decodeIfPresent(String.self, forKey: .connectionState) ?? "connected"
        isController = try container.decodeIfPresent(Bool.self, forKey: .isController) ?? false
    }

    init(userId: String, displayName: String, avatarURL: URL?, joinedAt: Date, bookReady: Bool, connectionState: String, isController: Bool) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.joinedAt = joinedAt
        self.bookReady = bookReady
        self.connectionState = connectionState
        self.isController = isController
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encode(joinedAt.timeIntervalSince1970 * 1_000, forKey: .joinedAt)
        try container.encode(bookReady, forKey: .bookReady)
        try container.encode(connectionState, forKey: .connectionState)
        try container.encode(isController, forKey: .isController)
    }
}

struct SharedReadingSession: Codable, Sendable, Equatable, Identifiable {
    let sessionId: String
    let status: SharedReadingSessionStatus
    let book: SharedReadingBook
    let controllerUserId: String
    let controllerGeneration: Int
    let roomEpoch: Int
    let participants: [SharedReadingParticipant]

    var id: String { sessionId }
}

struct SharedReadingSessionSummary: Codable, Sendable, Equatable, Identifiable {
    let sessionId: String
    let status: SharedReadingSessionStatus
    let book: SharedReadingBook
    let controllerUserId: String
    let joinedAt: Date

    var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId, status, book, controllerUserId, joinedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        status = try container.decode(SharedReadingSessionStatus.self, forKey: .status)
        book = try container.decode(SharedReadingBook.self, forKey: .book)
        controllerUserId = try container.decode(String.self, forKey: .controllerUserId)
        if let iso = try? container.decode(String.self, forKey: .joinedAt),
           let date = ISO8601DateFormatter().date(from: iso) {
            joinedAt = date
        } else if let raw = try? container.decode(Double.self, forKey: .joinedAt) {
            joinedAt = Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
        } else {
            joinedAt = .distantPast
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(status, forKey: .status)
        try container.encode(book, forKey: .book)
        try container.encode(controllerUserId, forKey: .controllerUserId)
        try container.encode(ISO8601DateFormatter().string(from: joinedAt), forKey: .joinedAt)
    }
}

struct SharedReadingAdmission: Codable, Sendable, Equatable {
    let admissionTicket: String
    let websocketURL: URL
    let roomEpoch: Int
    let connectionGeneration: Int
    let status: SharedReadingSessionStatus

    private enum CodingKeys: String, CodingKey {
        case admissionTicket
        case websocketURL = "wsUrl"
        case roomEpoch
        case connectionGeneration
        case status
    }
}

struct SharedReadingProgress: Codable, Sendable, Equatable {
    let sessionId: String
    let bookId: String
    let contentHash: String
    let format: SharedReadingBookFormat
    let sequence: Int64
    let position: String
    let isPlaying: Bool
    let ttsRate: Double
    let updatedAt: Date

    init(
        sessionId: String,
        bookId: String,
        contentHash: String,
        format: SharedReadingBookFormat = .epub,
        sequence: Int64,
        position: String,
        isPlaying: Bool,
        ttsRate: Double,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.bookId = bookId
        self.contentHash = contentHash
        self.format = format
        self.sequence = sequence
        self.position = position
        self.isPlaying = isPlaying
        self.ttsRate = ttsRate
        self.updatedAt = updatedAt
    }

    func supersedes(_ other: SharedReadingProgress) -> Bool {
        sequence > other.sequence
    }
}

struct SharedReadingCreateResponse: Codable, Sendable, Equatable {
    let sessionId: String
    let book: SharedReadingBook
    let shareURL: URL
    let status: SharedReadingSessionStatus
}

struct SharedReadingRedeemResponse: Codable, Sendable, Equatable {
    let inviteId: String
    let sessionId: String
    let book: SharedReadingBook
    let status: SharedReadingSessionStatus
    let redemptionId: String
}

struct SharedReadingJoin: Sendable, Equatable, Identifiable {
    let response: SharedReadingRedeemResponse
    let admission: SharedReadingAdmission
    var id: String { response.sessionId }
}

struct SharedReadingActiveResponse: Codable, Sendable, Equatable {
    let sessions: [SharedReadingSessionSummary]
}

struct SharedReadingRoomStatus: Codable, Sendable, Equatable {
    let sessionId: String
    let status: SharedReadingSessionStatus
    let roomEpoch: Int
    let controllerGeneration: Int
    let controllerUserId: String
    let maxParticipants: Int
    let participants: [SharedReadingParticipant]
    let removedUserIds: [String]

    private enum CodingKeys: String, CodingKey {
        case sessionId, status, roomEpoch, controllerGeneration, controllerUserId, maxParticipants, participants, removedUserIds
    }

    init(
        sessionId: String,
        status: SharedReadingSessionStatus,
        roomEpoch: Int,
        controllerGeneration: Int,
        controllerUserId: String,
        maxParticipants: Int,
        participants: [SharedReadingParticipant],
        removedUserIds: [String] = []
    ) {
        self.sessionId = sessionId
        self.status = status
        self.roomEpoch = roomEpoch
        self.controllerGeneration = controllerGeneration
        self.controllerUserId = controllerUserId
        self.maxParticipants = maxParticipants
        self.participants = participants
        self.removedUserIds = removedUserIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        status = try container.decode(SharedReadingSessionStatus.self, forKey: .status)
        roomEpoch = try container.decode(Int.self, forKey: .roomEpoch)
        controllerGeneration = try container.decode(Int.self, forKey: .controllerGeneration)
        controllerUserId = try container.decode(String.self, forKey: .controllerUserId)
        maxParticipants = try container.decode(Int.self, forKey: .maxParticipants)
        participants = try container.decode([SharedReadingParticipant].self, forKey: .participants)
        removedUserIds = try container.decodeIfPresent([String].self, forKey: .removedUserIds) ?? []
    }
}

struct SharedReadingTurnCredentials: Codable, Sendable, Equatable {
    struct IceServer: Codable, Sendable, Equatable {
        let urls: [String]
        let username: String?
        let credential: String?
    }
    let iceServers: [IceServer]
}
