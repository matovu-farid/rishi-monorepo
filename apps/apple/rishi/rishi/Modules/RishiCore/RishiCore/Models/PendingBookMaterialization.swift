import Foundation

public struct BookMaterializationToken: Sendable, Hashable, Codable {
    public let ownerID: UserID
    public let accountGeneration: UInt64
    public let bookID: BookID
    public let attemptID: UUID

    public init(ownerID: UserID, accountGeneration: UInt64, bookID: BookID, attemptID: UUID) {
        self.ownerID = ownerID
        self.accountGeneration = accountGeneration
        self.bookID = bookID
        self.attemptID = attemptID
    }
}

public enum BookMaterializationPhase: String, Sendable, Codable, CaseIterable {
    case registered, copying, prepared, promoting, promoted, ready, paused, failed, cancelled
}

public enum BookSourceKind: String, Sendable, Codable, CaseIterable {
    case securityScopedOriginal, ownedStaging
}

public struct VerifiedBookArtifacts: Sendable, Codable, Equatable {
    public let sha256: String
    public let byteCount: Int64
    public let stagingRelativePath: String
    public let destinationRelativePath: String
    public let preparedFileIdentifier: String?
    public let destinationFileIdentifier: String?
    public let promotionRevision: UUID?

    public init(sha256: String, byteCount: Int64, stagingRelativePath: String, destinationRelativePath: String, preparedFileIdentifier: String?, destinationFileIdentifier: String?, promotionRevision: UUID?) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.stagingRelativePath = stagingRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.preparedFileIdentifier = preparedFileIdentifier
        self.destinationFileIdentifier = destinationFileIdentifier
        self.promotionRevision = promotionRevision
    }
}

public struct PendingBookMaterialization: Sendable, Codable, Equatable {
    public let token: BookMaterializationToken
    public let sourceKind: BookSourceKind
    public let sourceBookmark: Data?
    public let ownedSourceRelativePath: String?
    public let sourceVersion: ManagedFileVersion
    public let expectedSHA256: String
    public let expectedByteCount: Int64
    public let stagingRelativePath: String
    public let destinationRelativePath: String
    public let phase: BookMaterializationPhase
    public let retryableErrorCode: String?
    public let preparedFileIdentifier: String?
    public let destinationFileIdentifier: String?
    public let promotionRevision: UUID?

    public init(token: BookMaterializationToken, sourceKind: BookSourceKind, sourceBookmark: Data?, ownedSourceRelativePath: String?, sourceVersion: ManagedFileVersion, expectedSHA256: String, expectedByteCount: Int64, stagingRelativePath: String, destinationRelativePath: String, phase: BookMaterializationPhase, retryableErrorCode: String? = nil, preparedFileIdentifier: String? = nil, destinationFileIdentifier: String? = nil, promotionRevision: UUID? = nil) {
        self.token = token
        self.sourceKind = sourceKind
        self.sourceBookmark = sourceBookmark
        self.ownedSourceRelativePath = ownedSourceRelativePath
        self.sourceVersion = sourceVersion
        self.expectedSHA256 = expectedSHA256
        self.expectedByteCount = expectedByteCount
        self.stagingRelativePath = stagingRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.phase = phase
        self.retryableErrorCode = retryableErrorCode
        self.preparedFileIdentifier = preparedFileIdentifier
        self.destinationFileIdentifier = destinationFileIdentifier
        self.promotionRevision = promotionRevision
    }
}
