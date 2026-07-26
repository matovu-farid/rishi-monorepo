import Foundation


/// Protocol seam so RishiChat does not import RishiSync (layer rule).
///
/// The app layer (rishi/AppDependencies) implements this by forwarding to
/// `SyncEngine.markConversationDirty(_:)` / `markMessageDirty(_:)`. A `nil`
/// hook injected into ``RishiChatService`` is the no-op default.
public protocol ChatDirtyHook: Sendable {
    func conversationDidUpdate(_ id: ConversationID) async
    func messageDidUpdate(_ id: MessageID) async
}

/// No-op `ChatDirtyHook` for tests, previews, and production until
/// `SyncEngine` wires the real forwarder in plan 09-06.
struct NoopChatDirtyHook: ChatDirtyHook {
    init() {}
    func conversationDidUpdate(_ id: ConversationID) async {}
    func messageDidUpdate(_ id: MessageID) async {}
}
