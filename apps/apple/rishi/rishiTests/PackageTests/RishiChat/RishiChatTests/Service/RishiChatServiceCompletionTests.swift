@testable import rishi
import Foundation
import Synchronization
import Testing

/// Uses the real WorkerClient byte buffering, parser and service. No production
/// account storage or network is touched; the protocol belongs only to this suite.
private final class CompletionURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case finish, failBeforeResponse, hold }
    private struct State {
        var body = Data()
        var mode = Mode.finish
        var requests = 0
        var stopped = 0
        var pending: CompletionURLProtocol?
    }
    private static let storage = Mutex(State())

    static func configure(body: Data, mode: Mode) {
        storage.withLock { $0 = State(body: body, mode: mode) }
    }
    static var requestCount: Int { storage.withLock { $0.requests } }
    static var stopCount: Int { storage.withLock { $0.stopped } }
    static func reset() { storage.withLock { $0 = State() } }
    static func failPending() {
        let pending = storage.withLock { state in
            let value = state.pending
            state.pending = nil
            return value
        }
        if let pending {
            pending.client?.urlProtocol(pending, didFailWithError: URLError(.networkConnectionLost))
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, mode) = Self.storage.withLock { state in
            state.requests += 1
            if case .hold = state.mode { state.pending = self }
            return (state.body, state.mode)
        }
        if case .failBeforeResponse = mode {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if case .finish = mode { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        Self.storage.withLock { state in
            if state.pending === self {
                state.stopped += 1
                state.pending = nil
            }
        }
    }
}

private actor CompletionWriteGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private enum CompletionCommitFailure: Error { case rejected }
private actor CompletionMessageStore: MessageStore {
    enum Failure: Sendable { case none, rejected, cancellation }
    private let backing = InMemoryMessageStore()
    private let gate: CompletionWriteGate?
    private let failure: Failure
    private(set) var assistantAttempts = 0
    private(set) var historyReads = 0
    private(set) var committedAssistants: [Message] = []
    init(gate: CompletionWriteGate? = nil, failure: Failure = .none) {
        self.gate = gate
        self.failure = failure
    }
    func messages(for conversationId: ConversationID) async throws -> [Message] {
        historyReads += 1
        return try await backing.messages(for: conversationId)
    }
    func message(_ id: MessageID) async throws -> Message? { try await backing.message(id) }
    func delete(_ id: MessageID) async throws { try await backing.delete(id) }
    func upsert(_ message: Message) async throws {
        if message.role == .assistant {
            assistantAttempts += 1
            await gate?.wait()
            switch failure {
            case .none: break
            case .rejected: throw CompletionCommitFailure.rejected
            case .cancellation: throw CancellationError()
            }
        }
        try await backing.upsert(message)
        if message.role == .assistant { committedAssistants.append(message) }
    }
}

private actor CompletionProbe {
    enum Failure: Sendable, Equatable {
        case transport(URLError.Code), commit, unexpected(String)
    }
    private(set) var events: [ChatEvent] = []
    private(set) var finished = false
    private(set) var failure: Failure?
    func record(_ event: ChatEvent) { events.append(event) }
    func finish(error: (any Error)? = nil) {
        if let error = error as? URLError { failure = .transport(error.code) }
        else if error is CompletionCommitFailure { failure = .commit }
        else if let error { failure = .unexpected(String(describing: error)) }
        finished = true
    }
}

@Suite("Chat persistence completion and failure propagation", .serialized)
struct RishiChatServiceCompletionTests {
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
    private func body(_ frames: String, padded: Bool = false) -> Data {
        // WorkerClient publishes 4096-byte chunks. Padding a valid SSE comment
        // exposes the first token before a held transport's next byte arrives.
        Data((frames + (padded ? ": " + String(repeating: "x", count: 8192) + "\n\n" : "")).utf8)
    }
    private func makeService(
        body: Data, mode: CompletionURLProtocol.Mode = .finish,
        store: CompletionMessageStore, conversation: Conversation? = nil
    ) -> (RishiChatService, URLSession) {
        CompletionURLProtocol.configure(body: body, mode: mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let worker = WorkerClient(
            baseURL: URL(string: "https://chat-completion.rishi.test")!,
            session: session, tokenProvider: StaticTokenProvider("fixture-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
        let userID = conversation?.userId ?? UUID()
        let service = RishiChatService(
            userIdProvider: { userID }, workerClient: worker,
            conversationLookup: ConversationLookup(store: InMemoryConversationStore(initial: conversation.map { [$0] } ?? [])),
            messageStore: store
        )
        return (service, session)
    }
    private func collect(_ service: RishiChatService, into probe: CompletionProbe) -> Task<Void, Never> {
        Task {
            do {
                for try await event in service.stream(query: "question", bookId: nil) {
                    await probe.record(event)
                }
                await probe.finish()
            } catch { await probe.finish(error: error) }
        }
    }

    @Test("explicit done, EOF and parser tail complete only after persistence", arguments: ["done", "eof", "tail"])
    func completionWaitsForCommit(termination: String) async throws {
        let gate = CompletionWriteGate()
        let store = CompletionMessageStore(gate: gate)
        let suffix = termination == "done" ? "data: {\"done\":true}\n\n" :
            (termination == "tail" ? "data: [DONE]" : "")
        let (service, session) = makeService(body: body("data: {\"delta\":\"answer\"}\n\n" + suffix), store: store)
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer {
            collector.cancel()
            Task { await gate.open() }
            session.invalidateAndCancel()
            CompletionURLProtocol.reset()
        }
        try #require(await eventually { await store.assistantAttempts == 1 })
        try #require(await eventually { await probe.events == [.token("answer")] })
        #expect(await probe.events == [.token("answer")])
        #expect(await probe.finished == false)
        #expect(await store.committedAssistants.isEmpty)
        await gate.open()
        try #require(await eventually { await probe.finished })
        #expect(await probe.events == [.token("answer"), .completed])
        #expect(await probe.failure == nil)
        #expect(await store.committedAssistants.map(\.content) == ["answer"])
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @Test("transport failure terminates with its original error", arguments: [false, true])
    func transportFailureTerminates(afterToken: Bool) async throws {
        let store = CompletionMessageStore()
        let (service, session) = makeService(
            body: body("data: {\"delta\":\"partial\"}\n\n", padded: true),
            mode: afterToken ? .hold : .failBeforeResponse, store: store
        )
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer { collector.cancel(); session.invalidateAndCancel(); CompletionURLProtocol.reset() }
        if afterToken {
            try #require(await eventually { await probe.events.contains(.token("partial")) })
            CompletionURLProtocol.failPending()
        }
        try #require(await eventually { await probe.finished })
        #expect(await probe.failure == .transport(.networkConnectionLost))
        #expect(await probe.events == (afterToken ? [.token("partial")] : []))
        #expect(await store.assistantAttempts == 0)
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @Test("assistant commit failure follows partial delta without completion or resend")
    func commitFailureIsVisible() async throws {
        let store = CompletionMessageStore(failure: .rejected)
        let (service, session) = makeService(body: body("data: {\"delta\":\"partial\"}\n\ndata: [DONE]\n\n"), store: store)
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer { collector.cancel(); session.invalidateAndCancel(); CompletionURLProtocol.reset() }
        try #require(await eventually { await probe.finished })
        #expect(await probe.events == [.token("partial")])
        #expect(await probe.failure == .commit)
        #expect(await store.assistantAttempts == 1)
        #expect(await store.committedAssistants.isEmpty)
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @Test("cancellation of stalled bytes finishes promptly and persists partial once")
    func cancellationDoesNotJoinStalledBytes() async throws {
        let store = CompletionMessageStore()
        let (service, session) = makeService(
            body: body("data: {\"delta\":\"partial\"}\n\n", padded: true), mode: .hold, store: store
        )
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer { collector.cancel(); session.invalidateAndCancel(); CompletionURLProtocol.reset() }
        try #require(await eventually { await probe.events.contains(.token("partial")) })
        let started = ContinuousClock.now
        collector.cancel()
        try #require(await eventually { await probe.finished })
        #expect(started.duration(to: .now) < .seconds(1))
        try #require(await eventually { await store.committedAssistants.count == 1 })
        #expect(await store.assistantAttempts == 1)
        #expect(await store.committedAssistants.map(\.content) == ["partial"])
        #expect(await probe.events == [.token("partial")])
        try #require(await eventually { CompletionURLProtocol.stopCount > 0 })
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @Test("cancellation thrown during finalization does not retry assistant insertion")
    func cancelledCommitIsNotFinalizedTwice() async throws {
        let gate = CompletionWriteGate()
        let store = CompletionMessageStore(gate: gate, failure: .cancellation)
        let (service, session) = makeService(body: body("data: {\"delta\":\"partial\"}\n\ndata: [DONE]\n\n"), store: store)
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer {
            collector.cancel()
            Task { await gate.open() }
            session.invalidateAndCancel()
            CompletionURLProtocol.reset()
        }
        try #require(await eventually { await store.assistantAttempts == 1 })
        await gate.open()
        try #require(await eventually { await probe.finished })
        // Failure would trigger a second attempt in the previous catch path.
        #expect(await store.assistantAttempts == 1)
        #expect(await probe.events == [.token("partial")])
        #expect(await store.committedAssistants.isEmpty)
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @Test("malformed frames remain tolerant and tools retain order before first done")
    func parserSemanticsArePreserved() async throws {
        let store = CompletionMessageStore()
        let frames = "data: malformed\n\ndata: {\"delta\":\"answer\"}\n\ndata: {\"tool_call\":\"lookup\"}\n\ndata: [DONE]\n\ndata: {\"delta\":\"ignored\"}\n\n"
        let (service, session) = makeService(body: body(frames), store: store)
        let probe = CompletionProbe()
        let collector = collect(service, into: probe)
        defer { collector.cancel(); session.invalidateAndCancel(); CompletionURLProtocol.reset() }
        try #require(await eventually { await probe.finished })
        #expect(await probe.events == [.token("answer"), .toolCall("lookup"), .completed])
        #expect(await store.committedAssistants.map(\.content) == ["answer"])
        #expect(CompletionURLProtocol.requestCount == 1)
    }

    @MainActor
    @Test("panel preserves draft and waits for committed completion before loading success history")
    func panelWaitsForAssistantCommit() async throws {
        let gate = CompletionWriteGate()
        let store = CompletionMessageStore(gate: gate)
        let conversation = Conversation(userId: UUID(), title: "panel")
        let (service, session) = makeService(
            body: body("data: {\"delta\":\"answer\"}\n\ndata: [DONE]\n\n"),
            store: store, conversation: conversation
        )
        let vm = ChatPanelViewModel(conversation: conversation, bookId: nil, chatService: service, messageStore: store)
        defer { vm.cancel(); session.invalidateAndCancel(); CompletionURLProtocol.reset(); Task { await gate.open() } }
        await vm.loadHistory()
        #expect(await store.historyReads == 1)
        vm.send(query: " raw draft ")
        #expect(await eventually { await store.assistantAttempts == 1 })
        #expect(vm.successfulTurnRevision == 0)
        #expect(vm.committedRawDraft == nil)
        #expect(vm.draftAfterCommittedTurn(" raw draft ") == " raw draft ")
        #expect(await store.historyReads == 1)
        #expect(vm.messages.isEmpty)
        await gate.open()
        await vm.activeTaskHandle?.value
        #expect(vm.successfulTurnRevision == 1)
        #expect(vm.committedRawDraft == " raw draft ")
        #expect(vm.draftAfterCommittedTurn(" raw draft ") == "")
        #expect(vm.draftAfterCommittedTurn("edited meanwhile") == "edited meanwhile")
        #expect(vm.messages.map(\.role) == [.user, .assistant])
        #expect(vm.messages.last?.content == "answer")
        #expect(await store.historyReads == 2)
        #expect(CompletionURLProtocol.requestCount == 1)
    }

}
