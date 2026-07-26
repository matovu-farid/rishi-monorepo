import Foundation

public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public let id: ConversationID
    public var userId: UserID
    public var bookId: BookID?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConversationID = UUID(),
        userId: UserID,
        bookId: BookID? = nil,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.bookId = bookId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
