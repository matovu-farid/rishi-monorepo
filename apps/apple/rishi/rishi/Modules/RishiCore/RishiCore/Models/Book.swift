import Foundation

public enum BookFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case epub
    case pdf
    case mobi
    case azw3
}

public struct Book: Codable, Sendable, Hashable, Identifiable {
    public let id: BookID
    public var userId: UserID
    public var title: String
    public var author: String?
    public var formatType: BookFormat
    public var addedAt: Date
    public var openedAt: Date?
    public var fileURL: String              // relative path under Application Support
    public var coverPath: String?           // relative path; nil if no cover extracted
    public var positionId: PositionID?
    public var conversationId: ConversationID?

    public init(
        id: BookID = UUID(),
        userId: UserID,
        title: String,
        author: String? = nil,
        formatType: BookFormat,
        addedAt: Date = Date(),
        openedAt: Date? = nil,
        fileURL: String,
        coverPath: String? = nil,
        positionId: PositionID? = nil,
        conversationId: ConversationID? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.author = author
        self.formatType = formatType
        self.addedAt = addedAt
        self.openedAt = openedAt
        self.fileURL = fileURL
        self.coverPath = coverPath
        self.positionId = positionId
        self.conversationId = conversationId
    }
}
