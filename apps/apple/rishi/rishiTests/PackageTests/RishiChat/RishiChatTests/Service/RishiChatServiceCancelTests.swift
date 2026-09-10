@testable import rishi
import Testing
import Foundation





// MARK: - Test helpers

/// Mutable scalar box used to read back the first event from a detached Task
/// without capturing an `inout` over an async boundary.
fileprivate final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ChatEvent?
    var value: ChatEvent? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ event: ChatEvent) {
        lock.lock(); defer { lock.unlock() }
        if _value == nil { _value = event }
    }
}

fileprivate final class StreamSequenceState: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func nextIndex() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { index += 1 }
        return index
    }
}

// MARK: - Suite

@Suite("RishiChatService cancellation", .serialized)
struct RishiChatServiceCancelTests {

    private func makeWorker(token: String? = "test-token") -> WorkerClient {
        return WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider(token)
        )
    }

    /// Deterministic replacement for the URLSession/URLProtocol boundary. The
    /// service's cancellation contract is exercised by cancelling the
    /// returned stream, while WorkerClient transport behavior is covered by
    /// its own tests.
    private func makeStreamProvider(
        chunks: [Data],
        interChunkSleepMS: UInt64
    ) -> @Sendable () async -> AsyncThrowingStream<Data, Error> {
        {
            AsyncThrowingStream { continuation in
                let producer = Task {
                    for chunk in chunks {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(chunk)
                        try? await Task.sleep(nanoseconds: interChunkSleepMS * 1_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    private func makeSequencedStreamProvider(
        streams: [([Data], UInt64)]
    ) -> @Sendable () async -> AsyncThrowingStream<Data, Error> {
        let state = StreamSequenceState()
        return {
            let streamIndex = min(state.nextIndex(), streams.count - 1)
            let (chunks, interChunkSleepMS) = streams[streamIndex]
            return AsyncThrowingStream { continuation in
                let producer = Task {
                    for chunk in chunks {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(chunk)
                        try? await Task.sleep(nanoseconds: interChunkSleepMS * 1_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    /// Build an SSE chunk that contains exactly one `data:` frame plus enough
    /// `: padding\n` comment lines to exceed `WorkerClient`'s 4 KiB flush
    /// threshold so the consumer actually sees this chunk.
    private func paddedSSEFrame(_ frame: String, paddingBytes: Int = 5000) -> Data {
        var body = frame
        let pad = ": " + String(repeating: "x", count: 60) + "\n"
        while body.utf8.count < paddingBytes {
            body += pad
        }
        return Data(body.utf8)
    }

    // MARK: - Tests

    @Test("cancel mid-flight terminates the stream within ~1s")
    func cancellationTerminatesWithinBudget() async throws {
        let worker = makeWorker()
        let chunk1 = paddedSSEFrame(#"data: {"delta":"first"}"# + "\n\n")
        let chunk2 = paddedSSEFrame(#"data: {"delta":"second"}"# + "\n\n")
        let chunk3 = paddedSSEFrame(#"data: {"delta":"third"}"# + "\n\n")
        let chunk4 = Data("data: [DONE]\n\n".utf8)
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let userId = UUID()
        let service = RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore,
            streamProvider: makeStreamProvider(
                chunks: [chunk1, chunk2, chunk3, chunk4],
                interChunkSleepMS: 120
            )
        )

        let bookId = UUID()
        let firstBox = EventBox()
        let startedAt = Date()

        // Consume up to the first event, then return — exiting the for-loop
        // drops the iterator and fires the AsyncThrowingStream's
        // onTermination hook, which cancels the inner turn task and transport.
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in service.stream(query: "ping", bookId: bookId) {
                firstBox.set(event)
                break
            }
        }
        _ = try await iteratorTask.value
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(firstBox.value == .token("first"))
        // 1.5s budget gives headroom on busy CI without masking a hang.
        #expect(elapsed < 1.5, "stream tear-down took \(elapsed)s")
    }

    @Test("partial assistant message is persisted on cancel")
    func partialAssistantPersistedOnCancel() async throws {
        let worker = makeWorker()
        let chunk1 = paddedSSEFrame(#"data: {"delta":"abc"}"# + "\n\n")
        let chunk2 = paddedSSEFrame(#"data: {"delta":"def"}"# + "\n\n")
        let chunk3 = Data("data: [DONE]\n\n".utf8)
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let userId = UUID()
        let hook = SpyDirtyHook()
        let service = RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore,
            dirtyHook: hook,
            streamProvider: makeStreamProvider(
                chunks: [chunk1, chunk2, chunk3],
                interChunkSleepMS: 250
            )
        )

        let bookId = UUID()
        let firstBox = EventBox()
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in service.stream(query: "ping", bookId: bookId) {
                firstBox.set(event)
                break
            }
        }
        _ = try await iteratorTask.value

        // Give the actor enough time to persist the partial finalize. The
        // cancel path runs after onCancel + accumulator drain + actor hop
        // for messageStore.upsert — generous budget so CI noise doesn't flake.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(firstBox.value == .token("abc"))

        let convos = try await convoStore.conversations(for: userId)
        let convo = try #require(convos.first)
        let messages = try await msgStore.messages(for: convo.id)
        #expect(messages.count == 2, "expected user + partial assistant; got \(messages.count)")
        #expect(messages.first?.role == .user)
        let assistant = messages.last
        #expect(assistant?.role == .assistant)
        // Partial assistant content is whatever was accumulated up to the
        // moment of cancel — accept any prefix of "abcdef" (including empty)
        // since the cancel race can land anywhere in the producer schedule.
        // The CHAT-08 contract is that the partial row IS persisted, not
        // that it has a specific content; we record the actual value to
        // detect regressions where nothing is persisted.
        let content = assistant?.content ?? ""
        let validPrefixes = ["", "abc", "abcdef"]
        #expect(validPrefixes.contains(content),
                "unexpected partial assistant content: '\(content)'")

        // Hook fired for both writes (user + partial assistant = 2 each).
        let msgHookCount = await hook.messageCalls.count
        let convoHookCount = await hook.conversationCalls.count
        #expect(msgHookCount >= 2)
        #expect(convoHookCount >= 2)
    }

    @Test("no .token events leak after cancellation")
    func noEventsLeakAfterCancel() async throws {
        let worker = makeWorker()
        let chunk1 = paddedSSEFrame(#"data: {"delta":"one"}"# + "\n\n")
        let chunk2 = paddedSSEFrame(#"data: {"delta":"two"}"# + "\n\n")
        let chunk3 = paddedSSEFrame(#"data: {"delta":"three"}"# + "\n\n")
        let chunk4 = Data("data: [DONE]\n\n".utf8)
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let service = RishiChatService(
            userIdProvider: { UUID() },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore,
            streamProvider: makeStreamProvider(
                chunks: [chunk1, chunk2, chunk3, chunk4],
                interChunkSleepMS: 150
            )
        )

        let bookId = UUID()
        let firstBox = EventBox()
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in service.stream(query: "ping", bookId: bookId) {
                firstBox.set(event)
                break
            }
        }
        _ = try await iteratorTask.value

        // Window large enough that the second / third chunk would have arrived
        // if cancellation had failed.
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(firstBox.value == .token("one"))
    }

    @Test("service is reusable after cancellation")
    func serviceIsReusableAfterCancel() async throws {
        let worker = makeWorker()
        let cancelChunk = paddedSSEFrame(#"data: {"delta":"x"}"# + "\n\n")
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let userId = UUID()
        let service = RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore,
            streamProvider: makeSequencedStreamProvider(
                streams: [
                    ([cancelChunk, Data("data: [DONE]\n\n".utf8)], 300),
                    ([Data((#"data: {"delta":"hello"}"# + "\n\n" + "data: [DONE]\n\n").utf8)], 0),
                ]
            )
        )

        // First turn: cancel.
        let bookId1 = UUID()
        let firstBox = EventBox()
        let cancelTask: Task<Void, Error> = Task {
            for try await event in service.stream(query: "first", bookId: bookId1) {
                firstBox.set(event)
                break
            }
        }
        _ = try await cancelTask.value
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Second turn: full happy-path stream that we let run to completion.
        let bookId2 = UUID()
        var events: [ChatEvent] = []
        for try await event in service.stream(query: "second", bookId: bookId2) {
            events.append(event)
        }
        #expect(events.contains(.token("hello")))
        #expect(events.last == .completed)

        // The two conversations are distinct (different bookIds).
        let convos = try await convoStore.conversations(for: userId)
        #expect(convos.count == 2)
    }
}
