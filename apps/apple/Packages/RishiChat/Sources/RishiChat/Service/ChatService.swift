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
        //
        //    The parser-side state lives in `AssistantAccumulator` (an actor)
        //    so a child Task can keep pushing tokens to it while the parent
        //    coordinates lifecycle. A child Task is necessary because the
        //    parent must remain responsive to its own cancellation: if the
        //    parent iterated `byteStream` directly, `for try await chunk in
        //    byteStream` would block on `iter.next()` between SSE chunks and
        //    not see cancellation until the next chunk arrived (potentially
        //    seconds later, exceeding the CHAT-08 cancel budget).
        //
        //    When the consumer cancels (drops the AsyncThrowingStream), the
        //    parent's `withTaskCancellationHandler` onCancel:
        //      1. cancels the child Task (which eventually drops the
        //         byteStream iterator and triggers WorkerClient.stream's own
        //         onTermination — cancelling the URLSessionTask)
        //      2. finishes the yieldChannel so the parent's `for await event
        //         in yieldChannel.stream` returns immediately
        //    The parent then finalizes the partial assistant content (CHAT-04
        //    preserved on mid-flight cancel) and rethrows CancellationError.
        let endpoint = ChatStreamEndpoint(body: ChatRequest(bookId: bookId, query: query))
        let parser = SSEParser()
        let accumulator = AssistantAccumulator()
        var finalized = false

        let byteStream = workerClient.stream(endpoint)
        let yieldChannel = AsyncStream<ChatEvent>.makeStream(bufferingPolicy: .unbounded)

        let consumer = Task { () async throws -> Bool in
            // Returns true when `.completed` was seen; false on clean stream end.
            for try await chunk in byteStream {
                try Task.checkCancellation()
                let events = await parser.consume(chunk)
                for event in events {
                    if case let .token(t) = event { await accumulator.append(t) }
                    yieldChannel.continuation.yield(event)
                    if event == .completed {
                        yieldChannel.continuation.finish()
                        return true
                    }
                }
            }
            try Task.checkCancellation()
            let tail = await parser.finalize()
            for event in tail {
                if case let .token(t) = event { await accumulator.append(t) }
                yieldChannel.continuation.yield(event)
                if event == .completed {
                    yieldChannel.continuation.finish()
                    return true
                }
            }
            yieldChannel.continuation.finish()
            return false
        }

        await withTaskCancellationHandler {
            for await event in yieldChannel.stream {
                if Task.isCancelled { break }
                continuation.yield(event)
            }
        } onCancel: {
            // Tear down the consumer — that drops its byteStream iterator,
            // which fires WorkerClient's onTermination hook and cancels the
            // URLSessionTask.
            consumer.cancel()
            yieldChannel.continuation.finish()
        }

        // After the channel drains, three cases:
        //   a) parent task cancelled  → consumer was cancelled by onCancel;
        //      finalize partial + rethrow CancellationError
        //   b) consumer threw          → bubble that error
        //   c) consumer returned       → consume result + finalize+yield as needed
        if Task.isCancelled {
            if !finalized {
                let content = await accumulator.value
                try? await finalizeAssistant(convo: convo, content: content)
            }
            throw CancellationError()
        }
        do {
            let sawCompleted = try await consumer.value
            if sawCompleted {
                let content = await accumulator.value
                try await finalizeAssistant(convo: convo, content: content)
                finalized = true
            } else {
                // Clean stream end without explicit `.completed` — finalize
                // and emit a synthetic `.completed` to keep the contract.
                let content = await accumulator.value
                try await finalizeAssistant(convo: convo, content: content)
                finalized = true
                continuation.yield(.completed)
            }
        } catch is CancellationError {
            if !finalized {
                let content = await accumulator.value
                try? await finalizeAssistant(convo: convo, content: content)
            }
            throw CancellationError()
        }
    }

    /// Actor-isolated string accumulator so the parent and child task can
    /// share the in-flight assistant content under strict concurrency.
    private actor AssistantAccumulator {
        private var content = ""
        func append(_ token: String) { content += token }
        var value: String { content }
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
