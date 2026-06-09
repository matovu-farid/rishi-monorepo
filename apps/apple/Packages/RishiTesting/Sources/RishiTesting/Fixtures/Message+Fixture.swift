import Foundation
import RishiCore

extension Message {
    public static func fixture(
        id: MessageID = UUID(),
        conversationId: ConversationID = UUID(),
        role: MessageRole = .user,
        content: String = "Fixture message content.",
        toolCalls: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            toolCalls: toolCalls,
            createdAt: createdAt
        )
    }
}
