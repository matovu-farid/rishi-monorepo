import Foundation
import RishiCore
import RishiLogging

/// Phase 16-05 chat inbound merge, extracted from `SyncEngine.runOnce` (plan
/// 34-10 SRP).
///
/// The legacy `ChangeApplier` `.conversation` / `.message` branches stay a
/// defensive `markClean` no-op; the real merge happens here so the engine can
/// drive the stores directly without widening `ChangeApplier`'s dep surface.
///
/// Behavior is byte-identical to the inline loops it replaces:
///   - **Conversations** — LWW by `updatedAt`. Drop the remote row when the
///     local row is newer-or-equal (`local.updatedAt >= convo.updatedAt`),
///     counting it as a conflict; otherwise upsert + `markClean`.
///   - **Messages** — append-only; the server is canonical, so every fetched
///     row is upserted unconditionally + `markClean`.
///
/// `MergeResult` mirrors `ChangeApplier.ApplyResult`'s shape. `chatRowsApplied`
/// is surfaced separately so the engine can decide whether to fire the
/// `ChatSyncRefreshDelegate` (it only fires when at least one chat row merged).
struct ChatInboundMerger: Sendable {

    struct MergeResult: Sendable, Equatable {
        /// Rows successfully upserted this merge (conversations + messages).
        var applied: Int = 0
        /// LWW drops where the local conversation was newer-or-equal.
        var conflicts: Int = 0
        /// Per-fetch error strings (same "conversations.fetch:" /
        /// "messages.fetch:" prefixes the engine used inline).
        var errors: [String] = []
        /// Count of chat rows that actually changed a store — drives the
        /// engine's `ChatSyncRefreshDelegate` gate.
        var chatRowsApplied: Int = 0
        init() {}
    }

    private let conversationsFetcher: ConversationsFetcher
    private let messagesFetcher: MessagesFetcher
    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private let metadataStore: any SyncMetadataStore

    init(
        conversationsFetcher: ConversationsFetcher,
        messagesFetcher: MessagesFetcher,
        conversationStore: any ConversationStore,
        messageStore: any MessageStore,
        metadataStore: any SyncMetadataStore
    ) {
        self.conversationsFetcher = conversationsFetcher
        self.messagesFetcher = messagesFetcher
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.metadataStore = metadataStore
    }

    /// Pull conversations then messages, applying the merge policy above.
    /// Ordering (conversations before messages) is preserved exactly.
    func merge() async -> MergeResult {
        var result = MergeResult()

        do {
            let convos = try await conversationsFetcher.fetch()
            for convo in convos {
                // LWW: drop remote if local is newer-or-equal.
                if let local = try await conversationStore.conversation(convo.id),
                   local.updatedAt >= convo.updatedAt {
                    result.conflicts += 1
                    continue
                }
                try await conversationStore.upsert(convo)
                try await metadataStore.markClean(
                    entityId: convo.id,
                    kind: .conversation,
                    lastSyncedAt: convo.updatedAt,
                    remoteEtag: nil
                )
                result.applied += 1
                result.chatRowsApplied += 1
            }
        } catch {
            result.errors.append("conversations.fetch: \(error)")
        }

        do {
            let msgs = try await messagesFetcher.fetch()
            for msg in msgs {
                // Messages are append-only locally — server is canonical;
                // unconditional upsert keyed by id is the right move.
                try await messageStore.upsert(msg)
                try await metadataStore.markClean(
                    entityId: msg.id,
                    kind: .message,
                    lastSyncedAt: msg.createdAt,
                    remoteEtag: nil
                )
                result.applied += 1
                result.chatRowsApplied += 1
            }
        } catch {
            result.errors.append("messages.fetch: \(error)")
        }

        return result
    }
}
