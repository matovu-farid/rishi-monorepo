import Foundation
import RishiCore
import RishiLogging

/// Forwarder for voice-session transcripts. The app layer implements this
/// AND `ChatDirtyHook` on a single adapter so the SyncEngine sees voice +
/// chat dirty marks uniformly.
///
/// Lives in RishiVoice (not RishiCore) because the dirty-hook concept is
/// a Phase-9 chat invention — lifting it into Core for one Feature reuse is
/// a bigger refactor than this protocol mirror.
public protocol VoiceTranscriptDirtyHook: Sendable {
    func conversationDidUpdate(_ id: ConversationID) async
    func messageDidUpdate(_ id: MessageID) async
}

/// No-op `VoiceTranscriptDirtyHook` for tests, previews, and production
/// until Plan 10-06 wires the real forwarder.
public struct NoopVoiceTranscriptDirtyHook: VoiceTranscriptDirtyHook {
    public init() {}
    public func conversationDidUpdate(_ id: ConversationID) async {}
    public func messageDidUpdate(_ id: MessageID) async {}
}

/// Consumes a `RealtimeClientAPI.transcriptStream()` and persists final
/// fragments as `Message` rows in `MessageStore`. Updates `VoiceSessionState`
/// with in-progress fragments so SwiftUI can render a live ticker.
///
/// VOICE-07: Final fragments are upserted via `MessageStore.upsert` keyed
/// by the conversation passed at session start, then the optional dirty hook
/// is fired so `SyncEngine` picks them up in the next push.
public actor VoiceTranscriptBridge {

    private let messageStore: any MessageStore
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let clock: @Sendable () -> Date
    /// Optional inactivity ping — fired on every transcript event (user and
    /// assistant, partial or final). Used by realtime to send
    /// `client_activity` without consuming a second `transcriptStream()`.
    private let onActivity: (@Sendable () async -> Void)?

    // Per-role accumulator: in-progress text waiting for an `isFinal` flush.
    private var userBuffer: String = ""
    private var assistantBuffer: String = ""

    public init(
        messageStore: any MessageStore,
        dirtyHook: any VoiceTranscriptDirtyHook = NoopVoiceTranscriptDirtyHook(),
        clock: @escaping @Sendable () -> Date = { Date() },
        onActivity: (@Sendable () async -> Void)? = nil
    ) {
        self.messageStore = messageStore
        self.dirtyHook = dirtyHook
        self.clock = clock
        self.onActivity = onActivity
    }

    /// Drive the bridge by iterating the given stream. Updates `state` on
    /// MainActor; persists finalized fragments to `messageStore`. Returns
    /// when the stream finishes or the task is cancelled.
    public func consume(
        stream: AsyncStream<RealtimeTranscriptEvent>,
        conversationId: ConversationID,
        state: VoiceSessionState
    ) async {
        for await event in stream {
            await ingest(event, conversationId: conversationId, state: state)
        }
    }

    // MARK: - Internals

    private func ingest(
        _ event: RealtimeTranscriptEvent,
        conversationId: ConversationID,
        state: VoiceSessionState
    ) async {
        if let onActivity {
            await onActivity()
        }

        // Update the in-progress buffer and push to the live UI state.
        switch event.role {
        case .user:      userBuffer += event.content
        case .assistant: assistantBuffer += event.content
        }
        await MainActor.run {
            state.appendTranscript(role: event.role, content: event.content)
        }

        guard event.isFinal else { return }

        let content: String
        switch event.role {
        case .user:      content = userBuffer;      userBuffer = ""
        case .assistant: content = assistantBuffer; assistantBuffer = ""
        }
        await MainActor.run {
            state.clearTranscript(role: event.role)
        }

        // Skip empty finals (defensive — the SDK occasionally flushes an
        // empty `isFinal=true` event at turn boundaries).
        guard !content.isEmpty else { return }

        let message = Message(
            conversationId: conversationId,
            role: messageRole(for: event.role),
            content: content,
            createdAt: clock()
        )
        do {
            try await messageStore.upsert(message)
            await dirtyHook.messageDidUpdate(message.id)
            await dirtyHook.conversationDidUpdate(conversationId)
            Log.event("voice.transcript.persisted", level: .info, data: [
                "role": event.role.rawValue,
                "length": String(content.count),
            ])
        } catch {
            Log.event("voice.transcript.persist.failed", level: .error, data: [
                "error": String(describing: error),
            ])
        }
    }

    private func messageRole(for role: TranscriptRole) -> MessageRole {
        switch role {
        case .user:      return .user
        case .assistant: return .assistant
        }
    }
}
