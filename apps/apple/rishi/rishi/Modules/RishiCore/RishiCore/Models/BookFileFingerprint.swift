import Foundation

public struct ManagedFileVersion: Sendable, Codable, Equatable {
    public let byteCount: Int64
    public let modificationDate: Date
    public let fileIdentifier: String?
    public let materializationRevision: UUID

    public init(byteCount: Int64, modificationDate: Date, fileIdentifier: String?, materializationRevision: UUID) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.fileIdentifier = fileIdentifier
        self.materializationRevision = materializationRevision
    }
}

public struct BookServerAcceptance: Sendable, Codable, Equatable {
    public let sha256: String
    public let acceptedOperationID: UUID
    public let acceptedAt: Date

    public init(sha256: String, acceptedOperationID: UUID, acceptedAt: Date) {
        self.sha256 = sha256
        self.acceptedOperationID = acceptedOperationID
        self.acceptedAt = acceptedAt
    }
}

public struct BookFileFingerprint: Sendable, Codable, Equatable {
    public let bookID: BookID
    public let ownerID: UserID
    public let sha256: String
    public let version: ManagedFileVersion
    public let serverAcceptance: BookServerAcceptance?

    public init(bookID: BookID, ownerID: UserID, sha256: String, version: ManagedFileVersion, serverAcceptance: BookServerAcceptance? = nil) {
        self.bookID = bookID
        self.ownerID = ownerID
        self.sha256 = sha256
        self.version = version
        self.serverAcceptance = serverAcceptance
    }
}
