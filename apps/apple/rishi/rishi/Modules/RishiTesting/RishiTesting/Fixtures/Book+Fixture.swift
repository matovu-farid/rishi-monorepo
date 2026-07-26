import Foundation


extension Book {
    /// Construct a `Book` with sensible defaults for unit tests.
    /// Override individual fields as needed.
    public static func fixture(
        id: BookID = UUID(),
        userId: UserID = UUID(),
        title: String = "Fixture Book",
        author: String? = "Fixture Author",
        formatType: BookFormat = .epub,
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        openedAt: Date? = nil,
        fileURL: String = "books/fixture.epub",
        coverPath: String? = nil,
        positionId: PositionID? = nil,
        conversationId: ConversationID? = nil
    ) -> Book {
        Book(
            id: id,
            userId: userId,
            title: title,
            author: author,
            formatType: formatType,
            addedAt: addedAt,
            openedAt: openedAt,
            fileURL: fileURL,
            coverPath: coverPath,
            positionId: positionId,
            conversationId: conversationId
        )
    }
}
