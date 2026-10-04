import Foundation

/// Stable authority to make local mutations to one canonical book version.
public struct BookReadingPermit: Sendable, Hashable, Codable {
    public let ownerID: UserID
    public let accountGeneration: UInt64
    public let bookID: BookID
    public let contentRevision: UUID

    public init(ownerID: UserID, accountGeneration: UInt64, bookID: BookID, contentRevision: UUID) {
        self.ownerID = ownerID
        self.accountGeneration = accountGeneration
        self.bookID = bookID
        self.contentRevision = contentRevision
    }
}
