import Foundation

public struct Position: Codable, Sendable, Hashable, Identifiable {
    public let id: PositionID
    public var bookId: BookID
    public var locator: String              // CFI for EPUB, page index/offset JSON for PDF
    public var percentComplete: Double      // 0.0 ... 1.0
    public var updatedAt: Date

    public init(
        id: PositionID = UUID(),
        bookId: BookID,
        locator: String,
        percentComplete: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.percentComplete = percentComplete
        self.updatedAt = updatedAt
    }
}
