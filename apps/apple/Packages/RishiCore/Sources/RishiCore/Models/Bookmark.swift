import Foundation

public struct Bookmark: Codable, Sendable, Hashable, Identifiable {
    public let id: BookmarkID
    public var bookId: BookID
    public var locator: String
    public var label: String?
    public var snippet: String?
    public var createdAt: Date

    public init(
        id: BookmarkID = UUID(),
        bookId: BookID,
        locator: String,
        label: String? = nil,
        snippet: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.label = label
        self.snippet = snippet
        self.createdAt = createdAt
    }
}
