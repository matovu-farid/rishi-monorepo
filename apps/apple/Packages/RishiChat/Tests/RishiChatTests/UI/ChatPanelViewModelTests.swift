import Testing
import Foundation
@testable import RishiChat
import RishiCore
import RishiTesting

/// Behavioral contract for ``ChatPanelViewModel``.
///
/// We exercise the viewmodel against in-memory stores and a scripted
/// `FakeChatService` so the test stays at the logic level — no SwiftUI
/// rendering, no network. Suite is `@MainActor` because the viewmodel itself
/// is `@MainActor`-isolated.
@MainActor
@Suite("ChatPanelViewModel", .serialized)
struct ChatPanelViewModelTests {

    // MARK: - Fixtures

    private func makeFixture(
        seeded: [Message] = [],
        script: FakeChatService.Script = .empty
    ) -> (
        vm: ChatPanelViewModel,
        service: FakeChatService,
        messageStore: InMemoryMessageStore,
        conversation: Conversation
    ) {
        let userId = UUID()
        let bookId = UUID()
        let convo = Conversation(userId: userId, bookId: bookId, title: "Test convo")
        let messageStore = InMemoryMessageStore(initial: seeded)
        let service = FakeChatService(script: script, conversationId: convo.id, messageStore: messageStore)
        let vm = ChatPanelViewModel(
            conversation: convo,
            bookId: bookId,
            chatService: service,
            messageStore: messageStore
        )
        return (vm, service, messageStore, convo)
    }

    // MARK: - 1. loadHistory

    @Test("loadHistory populates messages from the store, sorted by createdAt")
    func loadHistoryReadsFromStore() async {
        let convoId = UUID()
        let now = Date()
        let seed = [
            Message(conversationId: convoId, role: .user, content: "hi", createdAt: now),
            Message(conversationId: convoId, role: .assistant, content: "hello", createdAt: now.addingTimeInterval(1)),
        ]
        // Custom fixture so the seed shares conversationId with the VM's convo.
        let userId = UUID()
        let bookId = UUID()
        let convo = Conversation(id: convoId, userId: userId, bookId: bookId, title: "T")
        let store = InMemoryMessageStore(initial: seed)
        let svc = FakeChatService(script: .empty, conversationId: convo.id, messageStore: store)
        let vm = ChatPanelViewModel(
            conversation: convo,
            bookId: bookId,
            chatService: svc,
            messageStore: store
        )

        await vm.loadHistory()
        #expect(vm.messages.count == 2)
        #expect(vm.messages.first?.content == "hi")
        #expect(vm.messages.last?.content == "hello")
    }

    // MARK: - 2. send happy path

    @Test("send streams tokens, persists user+assistant, then reloads history")
    func sendHappyPathReloadsHistory() async {
        let f = makeFixture(script: .happy(tokens: ["he", "llo"]))
        f.vm.send(query: "Hi there")
        await f.vm.waitForActiveTask()

        // The fake service is responsible for persisting user + assistant
        // messages (mirroring RishiChatService's contract). After completion
        // the VM reloads history, so both rows must be visible.
        #expect(f.vm.messages.count == 2)
        let roles = f.vm.messages.map { $0.role }
        #expect(roles.contains(.user))
        #expect(roles.contains(.assistant))
        #expect(f.vm.streamingState.isStreaming == false)
        #expect(f.vm.streamingState.streamingMessage == nil)
        #expect(f.service.streamCallCount == 1)
    }

    // MARK: - 3. empty/whitespace rejected

    @Test("send(\"   \") is rejected; no service call, no state change")
    func sendWhitespaceRejected() async {
        let f = makeFixture(script: .happy(tokens: ["x"]))
        f.vm.send(query: "   \n\t  ")
        await f.vm.waitForActiveTask()
        #expect(f.service.streamCallCount == 0)
        #expect(f.vm.messages.isEmpty)
        #expect(f.vm.streamingState.isStreaming == false)
    }

    @Test("send(\"\") is rejected; no service call")
    func sendEmptyRejected() async {
        let f = makeFixture(script: .happy(tokens: ["x"]))
        f.vm.send(query: "")
        await f.vm.waitForActiveTask()
        #expect(f.service.streamCallCount == 0)
    }

    // MARK: - 4. cancel

    @Test("cancel mid-stream clears streaming state and reloads history")
    func cancelMidStreamClears() async {
        // A slow stream that yields a token then waits — VM cancels before
        // .completed arrives. The fake persists the user message before
        // yielding, so the post-cancel history still contains the user turn.
        let f = makeFixture(script: .slow(token: "partial"))
        f.vm.send(query: "what is this book about")

        // Give the stream a moment to persist the user message + start streaming.
        for _ in 0..<50 {
            if f.vm.streamingState.isStreaming { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        f.vm.cancel()
        await f.vm.waitForActiveTask()
        #expect(f.vm.streamingState.isStreaming == false)
        #expect(f.vm.streamingState.streamingMessage == nil)
        // User message persisted before cancel; visible on reload.
        #expect(f.vm.messages.contains(where: { $0.role == .user }))
    }

    // MARK: - 5. error path

    @Test("service error surfaces on streamingState.error and reloads history")
    func errorPathSurfacesError() async {
        let f = makeFixture(script: .error(SampleError.boom))
        f.vm.send(query: "ask anything")
        await f.vm.waitForActiveTask()
        #expect((f.vm.streamingState.error as? SampleError) == .boom)
        #expect(f.vm.streamingState.isStreaming == false)
    }
}

// MARK: - Fakes

private enum SampleError: Error, Equatable { case boom }

/// Scripted ``ChatService`` for VM tests. Persists user + assistant messages
/// itself so the VM's `loadHistory` reload after `.completed` / cancel / error
/// reflects realistic behavior (mirrors `RishiChatService`).
final class FakeChatService: ChatService, @unchecked Sendable {

    enum Script: Sendable {
        case empty
        case happy(tokens: [String])
        case slow(token: String)
        case error(Error)
    }

    private let script: Script
    private let conversationId: ConversationID
    private let messageStore: any MessageStore
    private let lock = NSLock()
    private var _streamCallCount = 0

    var streamCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _streamCallCount
    }

    init(script: Script, conversationId: ConversationID, messageStore: any MessageStore) {
        self.script = script
        self.conversationId = conversationId
        self.messageStore = messageStore
    }

    func stream(query: String, bookId: BookID?) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); _streamCallCount += 1; lock.unlock()
        let script = self.script
        let convoId = conversationId
        let store = messageStore
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Always persist the user message first (mirrors RishiChatService).
                let userMessage = Message(conversationId: convoId, role: .user, content: query)
                try? await store.upsert(userMessage)

                switch script {
                case .empty:
                    continuation.yield(.completed)
                    continuation.finish()
                case .happy(let tokens):
                    var accumulated = ""
                    for token in tokens {
                        continuation.yield(.token(token))
                        accumulated += token
                    }
                    let assistant = Message(conversationId: convoId, role: .assistant, content: accumulated)
                    try? await store.upsert(assistant)
                    continuation.yield(.completed)
                    continuation.finish()
                case .slow(let token):
                    continuation.yield(.token(token))
                    // Sleep until cancelled.
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                case .error(let err):
                    continuation.finish(throwing: err)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Test helper

extension ChatPanelViewModel {
    /// Awaits the in-flight task (if any) so tests can assert post-stream state
    /// without sprinkling sleeps.
    func waitForActiveTask() async {
        await activeTaskHandle?.value
    }
}
