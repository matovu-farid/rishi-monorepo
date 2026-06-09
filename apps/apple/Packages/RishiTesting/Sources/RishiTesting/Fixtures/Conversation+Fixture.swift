import Foundation
import RishiCore

extension Conversation {
    public static func fixture(
        id: ConversationID = UUID(),
        userId: UserID = UUID(),
        bookId: BookID? = nil,
        title: String = "Fixture Conversation",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_500)
    ) -> Conversation {
        Conversation(
            id: id,
            userId: userId,
            bookId: bookId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
