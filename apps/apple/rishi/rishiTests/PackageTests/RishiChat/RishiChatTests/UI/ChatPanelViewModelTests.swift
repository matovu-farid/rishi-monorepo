@testable import rishi
import Testing
import Foundation
import Synchronization




/// Behavioral contract for ``ChatPanelViewModel``.
///
/// We exercise the viewmodel against in-memory stores and a scripted
/// `RishiChatFakeChatService` so the test stays at the logic level — no SwiftUI
/// rendering, no network. Suite is `@MainActor` because the viewmodel itself
/// is `@MainActor`-isolated.
@MainActor
@Suite("ChatPanelViewModel", .serialized, .timeLimit(.minutes(1)))
struct ChatPanelViewModelTests {

    // MARK: - Fixtures

    private func makeFixture(
        seeded: [Message] = [],
        script: RishiChatFakeChatService.Script = .empty
    ) -> (
        vm: ChatPanelViewModel,
        service: RishiChatFakeChatService,
        messageStore: InMemoryMessageStore,
        conversation: Conversation
    ) {
        let userId = UUID()
        let bookId = UUID()
        let convo = Conversation(userId: userId, bookId: bookId, title: "Test convo")
        let messageStore = InMemoryMessageStore(initial: seeded)
        let service = RishiChatFakeChatService(script: script, conversationId: convo.id, messageStore: messageStore)
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
        let svc = RishiChatFakeChatService(script: .empty, conversationId: convo.id, messageStore: store)
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

        // The presentation flag precedes the service. Wait for its actual
        // user write and token yield before exercising mid-turn cancellation.
        await f.service.waitForSlowTurnStarted()
        f.vm.cancel()
        await f.vm.waitForActiveTask()
        #expect(f.vm.streamingState.isStreaming == false)
        #expect(f.vm.streamingState.streamingMessage == nil)
        // User message persisted before cancel; visible on reload.
        #expect(f.vm.messages.contains(where: { $0.role == .user }))
    }

    @Test("current canceled turn reloads history when a token already resumed its iterator")
    func bufferedTokenCancellationReloadsHistory() async throws {
        let conversation = Conversation(userId: UUID(), title: "buffered cancel")
        let user = Message(conversationId: conversation.id, role: .user, content: "persisted")
        let store = PanelHistoryStore(rows: [user])
        let service = PanelControlledService()
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: service, messageStore: store)
        vm.send(query: "ask")
        await service.waitForTurns(1)
        let turn = try #require(vm.activeTaskHandle)
        defer { vm.cancel(); service.finishAll() }
        // These synchronous MainActor calls resume the iterator with a token,
        // then cancel before its next MainActor segment processes that event.
        service.yield(.token("buffered"), turn: 0)
        vm.cancel()
        await turn.value
        #expect(vm.messages == [user])
        #expect(vm.streamingState.isStreaming == false)
        #expect(vm.streamingState.streamingMessage == nil)
        #expect(vm.streamingState.error == nil)
        #expect(vm.successfulTurnRevision == 0)
        #expect(vm.committedRawDraft == nil)
        #expect(service.queries == ["ask"])
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
    @Test("history failure retains rows and reload does not send again")
    func historyFailureRetainsTranscript() async throws {
        let conversation = Conversation(userId: UUID(), title: "fixture")
        let message = Message(conversationId: conversation.id, role: .user, content: "kept")
        let store = PanelHistoryStore(rows: [message])
        let service = PanelControlledService()
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: service, messageStore: store)
        await vm.loadHistory()
        await store.setFailure(true)
        await vm.loadHistory()
        #expect(vm.messages == [message])
        #expect(vm.historyError is SampleError)
        #expect(!vm.isLoadingHistory)
        await store.setFailure(false)
        await vm.loadHistory()
        #expect(vm.historyError == nil)
        #expect(service.queries.isEmpty)
    }

    @Test("late history request cannot replace a newer transcript or error", arguments: [false, true])
    func historyRequestOwnership(oldFailure: Bool) async {
        let conversation = Conversation(userId: UUID(), title: "fixture")
        let old = Message(conversationId: conversation.id, role: .user, content: "old")
        let newer = Message(conversationId: conversation.id, role: .assistant, content: "new")
        let store = PanelHistoryStore(rows: [old])
        await store.setFailure(oldFailure)
        let gate = PanelReadGate()
        await store.holdNextRead(gate)
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: PanelControlledService(), messageStore: store)
        let first = Task { await vm.loadHistory() }
        defer { first.cancel(); Task { await gate.open() } }
        await store.waitForReads(1)
        #expect(vm.isLoadingHistory)
        await store.setFailure(false)
        await store.setRows([newer])
        await vm.loadHistory()
        await gate.open()
        await first.value
        #expect(vm.messages == [newer])
        #expect(vm.historyError == nil)
        #expect(!vm.isLoadingHistory)
    }

    @Test("old canceled turn history and defer cannot control a replacement turn")
    func replacedTurnOwnership() async throws {
        let conversation = Conversation(userId: UUID(), title: "fixture")
        let store = PanelHistoryStore()
        let service = PanelControlledService()
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: service, messageStore: store)
        vm.send(query: "old")
        await service.waitForTurns(1)
        let oldTask = try #require(vm.activeTaskHandle)
        let gate = PanelReadGate()
        await store.holdNextRead(gate)
        vm.cancel()
        await store.waitForReads(1)
        vm.send(query: "new")
        await service.waitForTurns(2)
        let newTask = try #require(vm.activeTaskHandle)
        defer { vm.cancel(); service.finishAll(); Task { await gate.open() } }
        await gate.open()
        await oldTask.value
        #expect(vm.streamingState.isStreaming)
        #expect(vm.streamingState.error == nil)
        #expect(vm.successfulTurnRevision == 0)
        service.yield(.token("new token"), turn: 1)
        service.yield(.completed, turn: 1)
        service.finish(turn: 1)
        await newTask.value
        #expect(!vm.streamingState.isStreaming)
        #expect(vm.committedRawDraft == "new")
        #expect(vm.successfulTurnRevision == 1)
        #expect(service.queries == ["old", "new"])
    }

    @Test("a replaced queued send never starts an obsolete request")
    func queuedSendReplacement() async throws {
        let conversation = Conversation(userId: UUID(), title: "queued")
        let service = PanelControlledService()
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: service, messageStore: PanelHistoryStore())
        vm.send(query: "obsolete")
        let oldTask = try #require(vm.activeTaskHandle)
        // Neither MainActor task can start before this synchronous replacement.
        vm.send(query: "current")
        let currentTask = try #require(vm.activeTaskHandle)
        defer { vm.cancel(); service.finishAll() }
        await service.waitForTurns(1)
        await oldTask.value
        #expect(service.queries == ["current"])
        #expect(vm.streamingState.isStreaming)
        service.yield(.completed, turn: 0)
        service.finish(turn: 0)
        await currentTask.value
        #expect(vm.committedRawDraft == "current")
        #expect(vm.successfulTurnRevision == 1)
    }

    @Test("only matching committed raw draft clears; failure and cancel retain input")
    func committedDraftOwnership() async {
        let f = makeFixture(script: .happy(tokens: ["answer"]))
        f.vm.send(query: "  submitted ")
        await f.vm.waitForActiveTask()
        #expect(f.vm.committedRawDraft == "  submitted ")
        #expect(f.vm.draftAfterCommittedTurn("  submitted ") == "")
        #expect(f.vm.draftAfterCommittedTurn("edited later") == "edited later")
        #expect(f.vm.draftAfterCommittedTurn("submitted") == "submitted")
        let failing = makeFixture(script: .error(SampleError.boom))
        failing.vm.send(query: "failed draft")
        await failing.vm.waitForActiveTask()
        #expect(failing.vm.successfulTurnRevision == 0)
        #expect(failing.vm.draftAfterCommittedTurn("failed draft") == "failed draft")
        let canceled = makeFixture(script: .slow(token: "partial"))
        canceled.vm.send(query: "canceled draft")
        canceled.vm.cancel()
        await canceled.vm.waitForActiveTask()
        #expect(canceled.vm.successfulTurnRevision == 0)
        #expect(canceled.vm.draftAfterCommittedTurn("canceled draft") == "canceled draft")
    }

}

// MARK: - Fakes

private enum SampleError: Error, Equatable { case boom }

/// Scripted ``ChatService`` for VM tests. Persists user + assistant messages
/// itself so the VM's `loadHistory` reload after `.completed` / cancel / error
/// reflects realistic behavior (mirrors `RishiChatService`).
final class RishiChatFakeChatService: ChatService, @unchecked Sendable {

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
    private let slowTurnStarted = PanelCountSignal()

    func waitForSlowTurnStarted() async { await slowTurnStarted.wait(1) }

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
        let slowTurnStarted = self.slowTurnStarted
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
                    await slowTurnStarted.record(1)
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


private actor PanelReadGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let pending = waiting; waiting = []; for continuation in pending { continuation.resume() } }
}

private actor PanelCountSignal {
    private var count = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func record(_ count: Int) {
        self.count = count
        let ready = waiting.filter { $0.0 <= count }
        waiting.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
    }
    func wait(_ target: Int) async {
        if count < target { await withCheckedContinuation { waiting.append((target, $0)) } }
    }
}

private actor PanelHistoryStore: MessageStore {
    private var rows: [Message]
    private var fails = false
    private var nextGate: PanelReadGate?
    private var reads = 0
    private let signal = PanelCountSignal()
    init(rows: [Message] = []) { self.rows = rows }
    func setFailure(_ value: Bool) { fails = value }
    func setRows(_ value: [Message]) { rows = value }
    func holdNextRead(_ gate: PanelReadGate) { nextGate = gate }
    func waitForReads(_ count: Int) async { await signal.wait(count) }
    func messages(for conversationId: ConversationID) async throws -> [Message] {
        let captured = rows.filter { $0.conversationId == conversationId }
        let failure = fails
        let gate = nextGate
        nextGate = nil
        reads += 1
        await signal.record(reads)
        await gate?.wait()
        if failure { throw SampleError.boom }
        return captured
    }
    func message(_ id: MessageID) async throws -> Message? { rows.first { $0.id == id } }
    func upsert(_ message: Message) async throws { rows.removeAll { $0.id == message.id }; rows.append(message) }
    func delete(_ id: MessageID) async throws { rows.removeAll { $0.id == id } }
}

private final class PanelControlledService: ChatService, Sendable {
    private struct State {
        var queries: [String] = []
        var streams: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    }
    private let state = Mutex(State())
    private let signal = PanelCountSignal()
    var queries: [String] { state.withLock { $0.queries } }
    func stream(query: String, bookId: BookID?) -> AsyncThrowingStream<ChatEvent, Error> {
        let pair = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let count = state.withLock { value in
            value.queries.append(query); value.streams.append(pair.continuation)
            return value.queries.count
        }
        Task { await signal.record(count) }
        return pair.stream
    }
    func waitForTurns(_ count: Int) async { await signal.wait(count) }
    func yield(_ event: ChatEvent, turn: Int) { state.withLock { $0.streams[turn] }.yield(event) }
    func finish(turn: Int) { state.withLock { $0.streams[turn] }.finish() }
    func finishAll() { for stream in state.withLock({ $0.streams }) { stream.finish() } }
}
