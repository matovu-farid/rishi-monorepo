import Foundation
import RishiCore
import RishiAPI
import RishiLogging

/// Concrete ``ChatService`` for Phase 9.
///
/// Wires together:
///   - ``WorkerClient`` (SSE byte stream)
///   - ``SSEParser`` (frames → ``ChatEvent``)
///   - ``ConversationLookup`` (find-or-create per `(userId, bookId)`)
///   - ``MessageStore`` (persist user + assistant messages)
///   - optional ``ChatDirtyHook`` (forward to `SyncEngine` at app layer)
///
/// Cancellation contract (CHAT-08): callers cancel the consuming `Task`.
/// `AsyncThrowingStream.onTermination` is wired to cancel the outer turn task,
/// which cancels the inner `WorkerClient.stream` task — which in turn cancels
/// the underlying `URLSessionDataTask` (via `WorkerClient`'s own
/// `onTermination` hook). On cancellation, the partial assistant content
/// accumulated so far is persisted via ``MessageStore.upsert`` (preserves
/// CHAT-04 on mid-flight cancel) and the dirty hook fires for the partial
/// finalize so the next sync push includes the truncated assistant turn.
public actor RishiChatService: ChatService {

    private let userIdProvider: @Sendable () async -> UserID?
    private let workerClient: WorkerClient
    private let conversationLookup: ConversationLookup
    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private let dirtyHook: (any ChatDirtyHook)?
    private let clock: @Sendable () -> Date

    public init(
        userIdProvider: @escaping @Sendable () async -> UserID?,
        workerClient: WorkerClient,
        conversationLookup: ConversationLookup,
        conversationStore: any ConversationStore,
        messageStore: any MessageStore,
        dirtyHook: (any ChatDirtyHook)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userIdProvider = userIdProvider
        self.workerClient = workerClient
        self.conversationLookup = conversationLookup
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.dirtyHook = dirtyHook
        self.clock = clock
    }

    public nonisolated func stream(
        query: String,
        bookId: BookID?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(query: query, bookId: bookId, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    // Graceful cancel — partial assistant message already
                    // finalized inside runTurn.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func runTurn(
        query: String,
        bookId: BookID?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        guard let userId = await userIdProvider() else {
            throw RishiError.unauthenticated
        }

        // 1. Resolve / mint conversation.
        let convo = try await conversationLookup.findOrCreate(userId: userId, bookId: bookId)

        // 2. Persist the user message BEFORE opening the stream so a network
        //    failure or immediate cancel still leaves the user turn on disk.
        let userMessage = Message(
            conversationId: convo.id,
            role: .user,
            content: query,
            createdAt: clock()
        )
        try await messageStore.upsert(userMessage)
        try await bumpConversation(convo)
        await dirtyHook?.messageDidUpdate(userMessage.id)
        await dirtyHook?.conversationDidUpdate(convo.id)

        // 3. Stream from the worker, accumulate assistant content, finalize on
        //    either explicit `.completed`, clean stream end, or cancel.
        let endpoint = ChatStreamEndpoint(body: ChatRequest(bookId: bookId, query: query))
        let parser = SSEParser()
        var accumulated = ""
        var finalized = false

        let byteStream = workerClient.stream(endpoint)
        do {
            for try await chunk in byteStream {
                try Task.checkCancellation()
                let events = await parser.consume(chunk)
                for event in events {
                    if case let .token(t) = event { accumulated += t }
                    continuation.yield(event)
                    if event == .completed {
                        try await finalizeAssistant(convo: convo, content: accumulated)
                        finalized = true
                        return
                    }
                }
            }
            // Stream ended without explicit `.completed` — drain partial frame
            // (defensive), yield any tail events, then finalize + yield .completed.
            let tail = await parser.finalize()
            for event in tail {
                if case let .token(t) = event { accumulated += t }
                continuation.yield(event)
                if event == .completed {
                    try await finalizeAssistant(convo: convo, content: accumulated)
                    finalized = true
                    return
                }
            }
            try await finalizeAssistant(convo: convo, content: accumulated)
            finalized = true
            continuation.yield(.completed)
        } catch is CancellationError {
            // CHAT-08: preserve partial assistant content on cancel so the next
            // sync push includes the truncated turn.
            if !finalized {
                try? await finalizeAssistant(convo: convo, content: accumulated)
            }
            throw CancellationError()
        }
    }

    private func finalizeAssistant(convo: Conversation, content: String) async throws {
        let assistant = Message(
            conversationId: convo.id,
            role: .assistant,
            content: content,
            createdAt: clock()
        )
        try await messageStore.upsert(assistant)
        try await bumpConversation(convo)
        await dirtyHook?.messageDidUpdate(assistant.id)
        await dirtyHook?.conversationDidUpdate(convo.id)
    }

    private func bumpConversation(_ convo: Conversation) async throws {
        var updated = convo
        updated.updatedAt = clock()
        try await conversationStore.upsert(updated)
    }
}
