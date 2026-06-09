import Foundation

public protocol MessageStore: Sendable {
    func messages(for conversationId: ConversationID) async throws -> [Message]
    func upsert(_ message: Message) async throws
    func delete(_ id: MessageID) async throws
}
