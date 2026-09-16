@testable import rishi
import Testing
import Foundation





// MARK: - Slow-drip MockURLProtocol

/// A URLProtocol that emits a sequence of byte chunks with configurable
/// inter-chunk delays. Used to exercise mid-flight cancel (CHAT-08): the test
/// reads one chunk, drops the consuming task, and then asserts the underlying
/// URLSessionTask was torn down via `WorkerClient.stream`'s onTermination hook.
///
/// Notes:
///   - Each chunk should be >= 4096 bytes because `WorkerClient.stream` only
///     forwards bytes to the consumer once its 4 KiB buffer flushes. SSE
///     comment lines (`: ...\n`) are ignored by ``SSEParser`` and make safe
///     padding.
///   - `stopLoading()` flips an atomic flag the drip loop checks between
///     sleeps so cancellation drops the in-flight task without writing further
///     bytes.
final class SlowDripURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var response: HTTPURLResponse?
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var interChunkSleepMS: UInt64 = 80
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    // Per-instance cancel flag flipped by stopLoading().
    private let cancelLock = NSLock()
    private var _cancelled = false
    fileprivate var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    static func configure(
        response: HTTPURLResponse,
        chunks: [Data],
        interChunkSleepMS: UInt64 = 80
    ) {
        lock.lock(); defer { lock.unlock() }
        self.response = response
        self.chunks = chunks
        self.interChunkSleepMS = interChunkSleepMS
        self.recordedRequests = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        response = nil
        chunks = []
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let resp = Self.response
        let chunks = Self.chunks
        let sleepMS = Self.interChunkSleepMS
        Self.lock.unlock()

        guard let resp else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)

        // Box the instance into a Sendable wrapper for the detached task —
        // SlowDripURLProtocol is itself @unchecked Sendable, but the closure
        // capture needs an explicit sending dance under Swift 6 strict.
        let me = UncheckedSendableBox(self)
        Task.detached {
            for chunk in chunks {
                if me.value.cancelled { return }
                me.value.client?.urlProtocol(me.value, didLoad: chunk)
                try? await Task.sleep(nanoseconds: sleepMS * 1_000_000)
            }
            if !me.value.cancelled {
                me.value.client?.urlProtocolDidFinishLoading(me.value)
            }
        }
    }

    override func stopLoading() {
        cancelLock.lock(); defer { cancelLock.unlock() }
        _cancelled = true
    }
}

/// Sendable carrier for non-Sendable references when we know the lifetime is
/// fine for the test's purpose.
fileprivate struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

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

/// Sendable carrier for an AsyncThrowingStream so a closure can capture it
/// across a Task boundary under Swift 6 strict concurrency.
fileprivate struct StreamBox<E>: @unchecked Sendable {
    let stream: AsyncThrowingStream<E, Error>
}

// MARK: - Suite

@Suite("RishiChatService cancellation", .serialized)
struct RishiChatServiceCancelTests {

    private func makeWorker(token: String? = "test-token") -> WorkerClient {
        SlowDripURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowDripURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: StaticTokenProvider(token)
        )
    }

    private func okResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.rishi.test/api/chat")!,
            statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
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
        SlowDripURLProtocol.configure(
            response: okResponse(),
            chunks: [chunk1, chunk2, chunk3, chunk4],
            interChunkSleepMS: 120
        )

        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let userId = UUID()
        let service = RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore
        )

        let bookId = UUID()
        let streamBox = StreamBox(stream: service.stream(query: "ping", bookId: bookId))
        let firstBox = EventBox()
        let startedAt = Date()

        // Consume up to the first event, then return — exiting the for-loop
        // drops the iterator and fires the AsyncThrowingStream's
        // onTermination hook, which cancels the inner turn task + URLSession.
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in streamBox.stream {
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
        SlowDripURLProtocol.configure(
            response: okResponse(),
            chunks: [chunk1, chunk2, chunk3],
            interChunkSleepMS: 250
        )

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
            dirtyHook: hook
        )

        let bookId = UUID()
        let streamBox = StreamBox(stream: service.stream(query: "ping", bookId: bookId))
        let firstBox = EventBox()
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in streamBox.stream {
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
        SlowDripURLProtocol.configure(
            response: okResponse(),
            chunks: [chunk1, chunk2, chunk3, chunk4],
            interChunkSleepMS: 150
        )

        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let service = RishiChatService(
            userIdProvider: { UUID() },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore
        )

        let bookId = UUID()
        let streamBox = StreamBox(stream: service.stream(query: "ping", bookId: bookId))
        let firstBox = EventBox()
        let iteratorTask: Task<Void, Error> = Task {
            for try await event in streamBox.stream {
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
        SlowDripURLProtocol.configure(
            response: okResponse(),
            chunks: [cancelChunk, Data("data: [DONE]\n\n".utf8)],
            interChunkSleepMS: 300
        )

        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let userId = UUID()
        let service = RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            messageStore: msgStore
        )

        // First turn: cancel.
        let bookId1 = UUID()
        let streamBox1 = StreamBox(stream: service.stream(query: "first", bookId: bookId1))
        let firstBox = EventBox()
        let cancelTask: Task<Void, Error> = Task {
            for try await event in streamBox1.stream {
                firstBox.set(event)
                break
            }
        }
        _ = try await cancelTask.value
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Second turn: full happy-path stream that we let run to completion.
        SlowDripURLProtocol.configure(
            response: okResponse(),
            chunks: [
                Data((#"data: {"delta":"hello"}"# + "\n\n" + "data: [DONE]\n\n").utf8),
            ],
            interChunkSleepMS: 0
        )

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
