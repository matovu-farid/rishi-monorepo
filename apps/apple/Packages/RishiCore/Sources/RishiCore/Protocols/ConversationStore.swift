import Foundation

public protocol ConversationStore: Sendable {
    func conversations(for userId: UserID) async throws -> [Conversation]
    func conversation(_ id: ConversationID) async throws -> Conversation?
    func upsert(_ conversation: Conversation) async throws
    func delete(_ id: ConversationID) async throws
}
