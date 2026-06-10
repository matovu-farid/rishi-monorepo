import Testing
import Foundation
@testable import RishiChat
import RishiCore
import RishiAPI
import RishiTesting

// MARK: - Per-suite MockURLProtocol (RishiChat-local copy)

/// Test fixture intercepting URLSession requests via URLProtocol API. Local to
/// RishiChatTests because the RishiAPI test target's MockURLProtocol is not
/// public.
final class ChatMockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requestHandler = nil
        recordedRequests = []
    }

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        requestHandler = handler
    }

    static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Hook spy

/// Records every dirty-hook invocation so tests can assert ChatDirtyHook is
/// fanned out per message + per conversation write.
actor SpyDirtyHook: ChatDirtyHook {
    private(set) var conversationCalls: [ConversationID] = []
    private(set) var messageCalls: [MessageID] = []

    func conversationDidUpdate(_ id: ConversationID) async { conversationCalls.append(id) }
    func messageDidUpdate(_ id: MessageID) async { messageCalls.append(id) }
}

// MARK: - Suite

@Suite("RishiChatService happy path", .serialized)
struct RishiChatServiceTests {

    private func makeWorker(token: String? = "test-token") -> (WorkerClient, URL) {
        ChatMockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let base = URL(string: "https://api.rishi.test")!
        let client = WorkerClient(
            baseURL: base,
            session: session,
            tokenProvider: StaticTokenProvider(token)
        )
        return (client, base)
    }

    private func okResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.rishi.test/api/chat")!,
            statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }

    private func sseBody(_ frames: [String]) -> Data {
        Data(frames.joined().utf8)
    }

    private func makeService(
        userId: UserID = UUID(),
        hook: SpyDirtyHook? = nil,
        worker: WorkerClient,
        conversationStore: any ConversationStore,
        messageStore: any MessageStore
    ) -> RishiChatService {
        let lookup = ConversationLookup(store: conversationStore)
        return RishiChatService(
            userIdProvider: { userId },
            workerClient: worker,
            conversationLookup: lookup,
            conversationStore: conversationStore,
            messageStore: messageStore,
            dirtyHook: hook
        )
    }

    // 1. Happy path: tokens stream in order + completed event
    @Test("emits .token('he'), .token('llo'), .completed")
    func happyPathStreamsTokensThenCompleted() async throws {
        let (worker, _) = makeWorker()
        let bookId = UUID()
        ChatMockURLProtocol.setHandler { _ in
            let body = self.sseBody([
                #"data: {"delta":"he"}"# + "\n\n",
                #"data: {"delta":"llo"}"# + "\n\n",
                "data: [DONE]\n\n",
            ])
            return (self.okResponse(), body)
        }
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let service = makeService(
            worker: worker,
            conversationStore: convoStore,
            messageStore: msgStore
        )

        var events: [ChatEvent] = []
        for try await event in service.stream(query: "hi", bookId: bookId) {
            events.append(event)
        }

        #expect(events == [.token("he"), .token("llo"), .completed])
    }

    // 2. Messages persisted in order
    @Test("persists [.user(query), .assistant(\"hello\")] in createdAt order")
    func persistsUserThenAssistantInOrder() async throws {
        let (worker, _) = makeWorker()
        let userId = UUID()
        let bookId = UUID()
        ChatMockURLProtocol.setHandler { _ in
            let body = self.sseBody([
                #"data: {"delta":"he"}"# + "\n\n",
                #"data: {"delta":"llo"}"# + "\n\n",
                "data: [DONE]\n\n",
            ])
            return (self.okResponse(), body)
        }
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let service = makeService(
            userId: userId,
            worker: worker,
            conversationStore: convoStore,
            messageStore: msgStore
        )

        for try await _ in service.stream(query: "what is X?", bookId: bookId) {}

        let convos = try await convoStore.conversations(for: userId)
        let convo = try #require(convos.first)
        let messages = try await msgStore.messages(for: convo.id)
        #expect(messages.count == 2)
        #expect(messages.first?.role == .user)
        #expect(messages.first?.content == "what is X?")
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.content == "hello")
    }

    // 3. Conversation.updatedAt is bumped past its initial value
    @Test("Conversation.updatedAt is bumped on message writes")
    func conversationUpdatedAtBumpsAfterStream() async throws {
        let (worker, _) = makeWorker()
        let userId = UUID()
        let bookId = UUID()
        ChatMockURLProtocol.setHandler { _ in
            (self.okResponse(), self.sseBody([
                #"data: {"delta":"x"}"# + "\n\n",
                "data: [DONE]\n\n",
            ]))
        }
        let initial = Date(timeIntervalSinceReferenceDate: 0)
        let existing = Conversation(
            userId: userId,
            bookId: bookId,
            title: "Existing",
            createdAt: initial,
            updatedAt: initial
        )
        let convoStore = InMemoryConversationStore(initial: [existing])
        let msgStore = InMemoryMessageStore()
        let service = makeService(
            userId: userId,
            worker: worker,
            conversationStore: convoStore,
            messageStore: msgStore
        )

        for try await _ in service.stream(query: "hi", bookId: bookId) {}

        let after = try await convoStore.conversation(existing.id)
        #expect(after?.updatedAt ?? initial > initial)
    }

    // 4. Hook is invoked ≥ 2x for each side
    @Test("ChatDirtyHook receives ≥ 2 conversation + ≥ 2 message updates per turn")
    func dirtyHookCalledTwicePerSide() async throws {
        let (worker, _) = makeWorker()
        let bookId = UUID()
        let hook = SpyDirtyHook()
        ChatMockURLProtocol.setHandler { _ in
            (self.okResponse(), self.sseBody([
                #"data: {"delta":"x"}"# + "\n\n",
                "data: [DONE]\n\n",
            ]))
        }
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let service = makeService(
            hook: hook,
            worker: worker,
            conversationStore: convoStore,
            messageStore: msgStore
        )

        for try await _ in service.stream(query: "hi", bookId: bookId) {}

        let convoCount = await hook.conversationCalls.count
        let msgCount = await hook.messageCalls.count
        #expect(convoCount >= 2)
        #expect(msgCount >= 2)
    }

    // 5. Unauthenticated: throws RishiError.unauthenticated
    @Test("nil current user surfaces RishiError.unauthenticated")
    func unauthenticatedSurfacesError() async {
        let (worker, _) = makeWorker()
        let bookId = UUID()
        let convoStore = InMemoryConversationStore()
        let msgStore = InMemoryMessageStore()
        let lookup = ConversationLookup(store: convoStore)
        let service = RishiChatService(
            userIdProvider: { nil },
            workerClient: worker,
            conversationLookup: lookup,
            conversationStore: convoStore,
            messageStore: msgStore
        )

        let stream = service.stream(query: "hi", bookId: bookId)
        do {
            for try await _ in stream {
                Issue.record("expected throw before any event")
            }
            Issue.record("expected throw, got clean finish")
        } catch RishiError.unauthenticated {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
