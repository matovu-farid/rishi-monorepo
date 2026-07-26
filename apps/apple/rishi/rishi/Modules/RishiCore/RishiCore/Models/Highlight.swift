import Foundation

public enum HighlightColor: String, Codable, Sendable, CaseIterable, Hashable {
    case yellow
    case green
    case blue
    case pink
}

public struct Highlight: Codable, Sendable, Hashable, Identifiable {
    public let id: HighlightID
    public var bookId: BookID
    public var locatorStart: String
    public var locatorEnd: String
    public var color: HighlightColor
    public var text: String
    public var note: String?
    public var createdAt: Date

    public init(
        id: HighlightID = UUID(),
        bookId: BookID,
        locatorStart: String,
        locatorEnd: String,
        color: HighlightColor,
        text: String,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.locatorStart = locatorStart
        self.locatorEnd = locatorEnd
        self.color = color
        self.text = text
        self.note = note
        self.createdAt = createdAt
    }
}
