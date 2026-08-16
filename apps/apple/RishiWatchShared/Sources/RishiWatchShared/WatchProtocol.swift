import Foundation

public enum WatchProtocolConstants {
    public static let currentVersion = 1
    public static let maximumTextLength = 160
    public static let commandLifetime: TimeInterval = 120
}

public protocol WatchVersioned {
    var protocolVersion: Int { get }
}

public enum WatchRedactionTrust: String, Codable, Sendable, Equatable {
    case verified
    case unverified
}

public enum WatchAvailability: Equatable, Sendable {
    case unavailable
    case active
    case unknown(rawValue: String)
}

extension WatchAvailability: Codable {
    private enum CodingKeys: String, CodingKey { case tag, rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "unavailable": self = .unavailable
        case "active": self = .active
        default: self = .unknown(rawValue: try container.decodeIfPresent(String.self, forKey: .rawValue) ?? tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable: try container.encode("unavailable", forKey: .tag)
        case .active: try container.encode("active", forKey: .tag)
        case let .unknown(rawValue):
            try container.encode("unknown", forKey: .tag)
            try container.encode(rawValue, forKey: .rawValue)
        }
    }
}

public enum WatchProgressScope: Equatable, Sendable {
    case book
    case resource
    case unit
    case unknown(rawValue: String)
}

extension WatchProgressScope: Codable {
    public init(from decoder: Decoder) throws {
        let value = try String(from: decoder)
        switch value {
        case "book": self = .book
        case "resource": self = .resource
        case "unit": self = .unit
        default: self = .unknown(rawValue: value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .book: value = "book"
        case .resource: value = "resource"
        case .unit: value = "unit"
        case let .unknown(rawValue): value = rawValue
        }
        try value.encode(to: encoder)
    }
}

public enum WatchPlaybackCommand: Equatable, Sendable {
    case togglePlayback
    case previousUnit
    case nextUnit
    case stop
    case setPlaybackRate(Double)
    case unknown(rawValue: String)
}

extension WatchPlaybackCommand: Codable {
    private enum CodingKeys: String, CodingKey { case tag, rate, rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .tag) {
        case "togglePlayback": self = .togglePlayback
        case "previousUnit": self = .previousUnit
        case "nextUnit": self = .nextUnit
        case "stop": self = .stop
        case "setPlaybackRate": self = .setPlaybackRate(try container.decode(Double.self, forKey: .rate))
        case let tag: self = .unknown(rawValue: try container.decodeIfPresent(String.self, forKey: .rawValue) ?? tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .togglePlayback: try container.encode("togglePlayback", forKey: .tag)
        case .previousUnit: try container.encode("previousUnit", forKey: .tag)
        case .nextUnit: try container.encode("nextUnit", forKey: .tag)
        case .stop: try container.encode("stop", forKey: .tag)
        case let .setPlaybackRate(rate):
            try container.encode("setPlaybackRate", forKey: .tag)
            try container.encode(rate, forKey: .rate)
        case let .unknown(rawValue):
            try container.encode("unknown", forKey: .tag)
            try container.encode(rawValue, forKey: .rawValue)
        }
    }
}

public struct WatchPlaybackSnapshot: Codable, Equatable, Sendable, WatchVersioned {
    public let protocolVersion: Int
    public let processSessionID: UUID
    public let handshakeNonce: UUID
    public let activationSequence: UInt64
    public let serverSequence: UInt64
    public let redactionRevision: UInt64
    public let redactionTrust: WatchRedactionTrust
    public let playbackGeneration: UInt64
    public let accountGeneration: UInt64
    public let availability: WatchAvailability
    public let title: String?
    public let chapterTitle: String?
    public let progress: Double?
    public let isPlaying: Bool
    public let playbackRate: Double?
    public let supportedPlaybackRates: [Double]
    public let currentNarrationUnit: String?
    public let progressScope: WatchProgressScope?
    public let validUntil: Date

    public init(
        protocolVersion: Int = WatchProtocolConstants.currentVersion,
        processSessionID: UUID,
        handshakeNonce: UUID,
        activationSequence: UInt64,
        serverSequence: UInt64,
        redactionRevision: UInt64,
        redactionTrust: WatchRedactionTrust,
        playbackGeneration: UInt64,
        accountGeneration: UInt64,
        availability: WatchAvailability,
        title: String? = nil,
        chapterTitle: String? = nil,
        progress: Double? = nil,
        isPlaying: Bool = false,
        playbackRate: Double? = nil,
        supportedPlaybackRates: [Double] = [],
        currentNarrationUnit: String? = nil,
        progressScope: WatchProgressScope? = nil,
        validUntil: Date
    ) {
        self.protocolVersion = protocolVersion
        self.processSessionID = processSessionID
        self.handshakeNonce = handshakeNonce
        self.activationSequence = activationSequence
        self.serverSequence = serverSequence
        self.redactionRevision = redactionRevision
        self.redactionTrust = redactionTrust
        self.playbackGeneration = playbackGeneration
        self.accountGeneration = accountGeneration
        self.availability = availability
        self.title = title.map { String($0.prefix(WatchProtocolConstants.maximumTextLength)) }
        self.chapterTitle = chapterTitle.map { String($0.prefix(WatchProtocolConstants.maximumTextLength)) }
        self.progress = progress.map { min(max($0, 0), 1) }
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.supportedPlaybackRates = supportedPlaybackRates
        self.currentNarrationUnit = currentNarrationUnit.map { String($0.prefix(WatchProtocolConstants.maximumTextLength)) }
        self.progressScope = progress
            .flatMap { _ in progressScope }
        self.validUntil = validUntil
    }
}

public struct WatchSnapshotRequest: Codable, Equatable, Sendable, WatchVersioned {
    public let protocolVersion: Int
    public let watchClientID: UUID
    public let handshakeNonce: UUID
    public let activationSequence: UInt64

    public init(watchClientID: UUID, handshakeNonce: UUID, activationSequence: UInt64, protocolVersion: Int = WatchProtocolConstants.currentVersion) {
        self.protocolVersion = protocolVersion
        self.watchClientID = watchClientID
        self.handshakeNonce = handshakeNonce
        self.activationSequence = activationSequence
    }
}

public struct WatchMutatingCommandEnvelope: Codable, Equatable, Sendable, WatchVersioned {
    public let protocolVersion: Int
    public let processSessionID: UUID
    public let watchClientID: UUID
    public let handshakeNonce: UUID
    public let activationSequence: UInt64
    public let clientSequence: UInt64
    public let requestID: UUID
    public let issuedAt: Date
    public let playbackGeneration: UInt64
    public let accountGeneration: UInt64
    public let command: WatchPlaybackCommand

    public init(processSessionID: UUID, watchClientID: UUID, handshakeNonce: UUID, activationSequence: UInt64, clientSequence: UInt64, requestID: UUID, issuedAt: Date = Date(), playbackGeneration: UInt64, accountGeneration: UInt64, command: WatchPlaybackCommand, protocolVersion: Int = WatchProtocolConstants.currentVersion) {
        self.protocolVersion = protocolVersion
        self.processSessionID = processSessionID
        self.watchClientID = watchClientID
        self.handshakeNonce = handshakeNonce
        self.activationSequence = activationSequence
        self.clientSequence = clientSequence
        self.requestID = requestID
        self.issuedAt = issuedAt
        self.playbackGeneration = playbackGeneration
        self.accountGeneration = accountGeneration
        self.command = command
    }
}

public enum WatchAcknowledgementDisposition: String, Codable, Sendable { case terminal, deferred }
public enum WatchRejectionReason: String, Codable, Sendable {
    case unsupportedVersion, staleGeneration, staleProcess, fenced, busy, notReachable
    case noActivePlayback, invalidCommand, accountUnavailable, executionFailed, executionTimedOut
}

public struct WatchAcknowledgement: Codable, Equatable, Sendable, WatchVersioned {
    public let protocolVersion: Int
    public let requestID: UUID?
    public let disposition: WatchAcknowledgementDisposition
    public let accepted: Bool
    public let rejectionReason: WatchRejectionReason?
    public let serverSequence: UInt64
    public let snapshot: WatchPlaybackSnapshot

    public init(requestID: UUID?, disposition: WatchAcknowledgementDisposition, accepted: Bool, rejectionReason: WatchRejectionReason? = nil, serverSequence: UInt64, snapshot: WatchPlaybackSnapshot, protocolVersion: Int = WatchProtocolConstants.currentVersion) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.disposition = disposition
        self.accepted = accepted
        self.rejectionReason = rejectionReason
        self.serverSequence = serverSequence
        self.snapshot = snapshot
    }
}

public struct WatchRedactionMarker: Codable, Equatable, Sendable {
    public let processSessionID: UUID
    public let redactionRevision: UInt64
    public let minimumAccountGeneration: UInt64

    public init(processSessionID: UUID, redactionRevision: UInt64, minimumAccountGeneration: UInt64) {
        self.processSessionID = processSessionID
        self.redactionRevision = redactionRevision
        self.minimumAccountGeneration = minimumAccountGeneration
    }
}
