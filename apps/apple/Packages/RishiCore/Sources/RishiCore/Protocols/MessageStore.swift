import Foundation

public protocol MessageStore: Sendable {
    func messages(for conversationId: ConversationID) async throws -> [Message]
    /// One-row accessor by message id. Added in Phase 16-04 so the outbound
    /// `MessageUploader` can resolve a `SyncQueueItem.entityId` (the message id)
    /// without knowing the parent `conversationId`.
    func message(_ id: MessageID) async throws -> Message?
    func upsert(_ message: Message) async throws
    func delete(_ id: MessageID) async throws
}
