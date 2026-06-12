import Foundation

/// Phase 16-05 — UI seam between the `SyncEngine` and the chat-tab
/// view-model.
///
/// `SyncEngine.runOnce` invokes `chatSyncDidMerge()` after a wave applies
/// at least one inbound conversation or message row. The app layer's
/// implementation hops to MainActor and calls
/// `ConversationsListViewModel.refreshAfterSync(userId:)` so the
/// Conversations tab reflects the just-merged rows without notification-
/// center wiring.
///
/// Pattern mirrors the existing Phase-7 `SyncStatus` binding (which uses
/// the same observation seam from `SyncEngine.bind(status:)`).
public protocol ChatSyncRefreshDelegate: Sendable {
    /// Called from the engine actor after at least one chat row was
    /// merged on the current wave. Implementations are expected to be
    /// fast and non-throwing; expensive UI reload work should be hopped
    /// to the MainActor inside the implementation.
    func chatSyncDidMerge() async
}
