import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable, Hashable {
    case user
    case assistant
    case system
}

public struct Message: Codable, Sendable, Hashable, Identifiable {
    public let id: MessageID
    public var conversationId: ConversationID
    public var role: MessageRole
    public var content: String
    public var toolCalls: String?           // opaque JSON blob; v1 does not introspect
    public var createdAt: Date

    public init(
        id: MessageID = UUID(),
        conversationId: ConversationID,
        role: MessageRole,
        content: String,
        toolCalls: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }
}
