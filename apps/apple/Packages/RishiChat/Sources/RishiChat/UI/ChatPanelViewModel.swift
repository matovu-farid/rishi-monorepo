import Foundation
import Observation
import RishiCore
import RishiLogging

/// Owns the in-flight chat ``Task`` and exposes it to ``ChatPanelView``.
///
/// Construction is the app layer's responsibility: the viewmodel needs the
/// resolved ``Conversation`` (so the panel is bound to a `(userId, bookId)`
/// pair already), a ``ChatService`` to drive the turn, and a ``MessageStore``
/// for history reload after each turn / cancel / error.
///
/// Threading: `@MainActor` because the SwiftUI panel binds directly to
/// `messages` + `streamingState` and we want zero actor hops on the render
/// path.
@MainActor
@Observable
public final class ChatPanelViewModel {

    // MARK: - Public surface

    public let conversation: Conversation
    public let bookId: BookID?
    public private(set) var messages: [Message] = []
    public let streamingState: ChatStreamingState

    // MARK: - Dependencies

    private let chatService: any ChatService
    private let messageStore: any MessageStore

    // MARK: - In-flight task
    //
    // `internal` (not private) so the test target can `await activeTaskHandle?
    // .value` to deterministically join the running turn instead of polling
    // sleeps. The handle is `Task<Void, Never>` because the body absorbs all
    // errors (they land on `streamingState.error`).
    var activeTaskHandle: Task<Void, Never>?

    // MARK: - Init

    public init(
        conversation: Conversation,
        bookId: BookID?,
        chatService: any ChatService,
        messageStore: any MessageStore,
        streamingState: ChatStreamingState = ChatStreamingState()
    ) {
        self.conversation = conversation
        self.bookId = bookId
        self.chatService = chatService
        self.messageStore = messageStore
        self.streamingState = streamingState
    }

    // MARK: - Public API

    /// Refreshes `messages` from the store. Swallows + logs errors — a failed
    /// history load must never crash the panel; the UI shows whatever was
    /// previously loaded.
    public func loadHistory() async {
        do {
            messages = try await messageStore.messages(for: conversation.id)
        } catch {
            Log.event("chat.history.load.failed", level: .error, data: [
                "error": "\(error)",
            ])
        }
    }

    /// Runs one chat turn. Empty / whitespace queries are rejected at this
    /// layer so the composer can blindly forward the textfield value.
    ///
    /// The streaming Task is stored so ``cancel()`` can tear it down; any
    /// previous in-flight turn is cancelled first.
    public func send(query rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        activeTaskHandle?.cancel()
        streamingState.beginStreaming()

        let service = chatService
        let bookId = self.bookId
        let state = streamingState

        activeTaskHandle = Task { [weak self] in
            // Always reload history at the end so the UI shows whatever the
            // service managed to persist (full turn / partial cancel / error).
            defer { state.endStreaming() }
            do {
                for try await event in service.stream(query: query, bookId: bookId) {
                    switch event {
                    case .token(let token):
                        state.appendToken(token)
                    case .toolCall:
                        // v1 does not render tool calls — opaque to the UI.
                        continue
                    case .completed:
                        await self?.loadHistory()
                        return
                    }
                }
                // Stream finished without an explicit `.completed`. Treat as
                // success — service contract finalises the assistant row
                // either way.
                await self?.loadHistory()
            } catch is CancellationError {
                await self?.loadHistory()
            } catch {
                state.failStreaming(error)
                await self?.loadHistory()
            }
        }
    }

    /// Cancels the in-flight turn. Safe to call when idle. The stored Task
    /// teardown clears `streamingState` via its `defer`, and the history
    /// reload (also in the same Task) picks up any partial assistant row the
    /// service persisted before cancel.
    public func cancel() {
        activeTaskHandle?.cancel()
        // Do NOT nil out the handle here — the Task is still draining its
        // defer block (which calls loadHistory + endStreaming). Tests that
        // `await activeTaskHandle?.value` depend on the handle surviving
        // until the Task body returns.
    }
}
