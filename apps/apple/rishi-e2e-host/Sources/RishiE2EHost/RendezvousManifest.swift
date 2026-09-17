import Foundation

public struct RendezvousManifest: Codable, Sendable, Equatable {
    public let runID: String
    public let fixture: RealBookFixture.Manifest
    public let ownerEmail: String
    public let participantEmail: String
    public let ownerDestination: SharedReadingDestination
    public let participantDestination: SharedReadingDestination
    public let rendezvousPath: String

    public init(runID: String, fixture: RealBookFixture.Manifest, ownerEmail: String, participantEmail: String, ownerDestination: SharedReadingDestination, participantDestination: SharedReadingDestination, rendezvousPath: String) {
        self.runID = runID
        self.fixture = fixture
        self.ownerEmail = ownerEmail
        self.participantEmail = participantEmail
        self.ownerDestination = ownerDestination
        self.participantDestination = participantDestination
        self.rendezvousPath = rendezvousPath
    }
}

public struct HostRunManifest: Encodable, Sendable, Equatable, CustomStringConvertible {
    public let runID: String
    public let owner: TestAccountCredentials
    public let participant: TestAccountCredentials
    public let fixture: RealBookFixture.Manifest
    public let manifestPath: String
    public let ownerDestination: SharedReadingDestination
    public let participantDestination: SharedReadingDestination
    public let rendezvousPath: String

    public init(runID: String, owner: TestAccount, participant: TestAccount, fixture: RealBookFixture.Manifest, manifestPath: String = "", ownerDestination: SharedReadingDestination, participantDestination: SharedReadingDestination, rendezvousPath: String) {
        self.runID = runID
        self.owner = owner.credentials
        self.participant = participant.credentials
        self.fixture = fixture
        self.manifestPath = manifestPath
        self.ownerDestination = ownerDestination
        self.participantDestination = participantDestination
        self.rendezvousPath = rendezvousPath
    }

    public var redacted: RendezvousManifest {
        RendezvousManifest(
            runID: runID,
            fixture: fixture,
            ownerEmail: owner.email,
            participantEmail: participant.email,
            ownerDestination: ownerDestination,
            participantDestination: participantDestination,
            // Logs may identify the rendezvous artifact, but must not expose
            // the host's temporary directory or fixture path.
            rendezvousPath: URL(fileURLWithPath: rendezvousPath).lastPathComponent
        )
    }

    public var redactedJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(redacted)) ?? Data(), as: UTF8.self)
    }

    public var description: String { redactedJSON }

    private enum CodingKeys: String, CodingKey {
        case runID, owner, participant, fixture, manifestPath
        case ownerDestination, participantDestination, rendezvousPath
    }

    private struct PersistedAccount: Encodable {
        let role: TestAccountRole
        let email: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        // Passwords and bearer tokens are intentionally absent from the
        // manifest. The host passes credentials directly in each XCTest
        // process environment; there is no reason to persist a second copy.
        try container.encode(PersistedAccount(role: owner.role, email: owner.email), forKey: .owner)
        try container.encode(PersistedAccount(role: participant.role, email: participant.email), forKey: .participant)
        try container.encode(fixture, forKey: .fixture)
        try container.encode(manifestPath, forKey: .manifestPath)
        try container.encode(ownerDestination, forKey: .ownerDestination)
        try container.encode(participantDestination, forKey: .participantDestination)
        try container.encode(rendezvousPath, forKey: .rendezvousPath)
    }
}

public struct RendezvousRecord: Codable, Sendable, Equatable {
    public let runID: String
    public let inviteToken: String

    public init(runID: String, inviteToken: String) {
        self.runID = runID
        self.inviteToken = inviteToken
    }
}

public protocol SharedReadingRendezvous: Sendable {
    func writeManifest(_ manifest: HostRunManifest, to url: URL) throws
    func waitForInvite(at url: URL, timeout: Duration) async throws -> String
    func removeManifest(at url: URL) throws
    func removeManifest(at url: URL, rendezvousURL: URL?) throws
}

public extension SharedReadingRendezvous {
    func removeManifest(at url: URL, rendezvousURL: URL?) throws {
        try removeManifest(at: url)
    }
}

public enum RendezvousError: Error, LocalizedError, Equatable {
    case timedOut
    case invalidRecord

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "Timed out waiting for the owner invite."
        case .invalidRecord: return "The rendezvous record is invalid."
        }
    }
}

public struct RendezvousFileStore: SharedReadingRendezvous {
    public init() {}

    public func writeManifest(_ manifest: HostRunManifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func waitForInvite(at url: URL, timeout: Duration) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let record = try? JSONDecoder().decode(RendezvousRecord.self, from: data),
               !record.inviteToken.isEmpty {
                return record.inviteToken
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RendezvousError.timedOut
    }

    public func removeManifest(at url: URL) throws {
        try removeManifest(at: url, rendezvousURL: nil)
    }

    public func removeManifest(at url: URL, rendezvousURL: URL?) throws {
        let fileManager = FileManager.default
        let rendezvousBase = rendezvousURL ?? url.appendingPathExtension("invite")
        let inviteURL = rendezvousBase
        let participantReadyURL = rendezvousBase.appendingPathExtension("participant-ready")
        let participantProgressURL = rendezvousBase.appendingPathExtension("participant-progress")
        let participantRejoinedURL = rendezvousBase.appendingPathExtension("participant-rejoined")
        let participantPlaybackURL = rendezvousBase.appendingPathExtension("participant-playback")
        let targets = [url, inviteURL, participantReadyURL, participantProgressURL, participantRejoinedURL, participantPlaybackURL]
        for target in targets where fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }
}
