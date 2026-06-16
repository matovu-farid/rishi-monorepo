import Testing
import Foundation
@testable import RishiVoice
import RishiSearch

/// Behavioral coverage of `BookContextResponder` against `FakeRealtimeClient`
/// + `StubBookSearch`. Each test follows the same skeleton:
///   1. Wire fake client + stub search + responder.
///   2. Start `consume` in a Task.
///   3. Inject a tool-call event.
///   4. Drain briefly via `Task.sleep`, cancel the consume Task.
///   5. Assert against `sentToolResultsSnapshot()`.
///
/// `FakeRealtimeClient.inject(toolCall:)` has replay-on-subscribe semantics
/// (Plan 25-07), so injecting BEFORE or AFTER the Task starts both work.
@Suite("BookContextResponder")
struct BookContextResponderTests {

    @Test
    func happyPath_returnsHitsAsJSONArray() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [
                BookSearchHit(text: "alpha", page: 1, score: 0.9),
                BookSearchHit(text: "beta", page: 2, score: 0.8),
                BookSearchHit(text: "gamma", page: 3, score: 0.7),
            ],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c1",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "c1")

        // Parse payload back to JSON to assert shape.
        let payloadData = Data((sent.first?.payload ?? "").utf8)
        let parsed = try JSONSerialization.jsonObject(with: payloadData) as? [[String: Any]]
        #expect(parsed?.count == 3)
        #expect(parsed?[0]["text"] as? String == "alpha")
        #expect(parsed?[0]["page"] as? Int == 1)
        // JSON numbers decode as NSNumber on Apple platforms; compare via Double.
        #expect((parsed?[0]["score"] as? Double) == 0.9)
    }

    @Test
    func coldStart_indexingStatus_returnsSentinel() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "ignored", page: 99, score: 0.5)],
            status: .indexing(chunksDone: 3, chunksTotal: 10)
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-indexing",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"anything\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "c-indexing")
        #expect(sent.first?.payload == BookContextResponder.coldStartSentinel)
    }

    @Test
    func coldStart_notIndexedStatus_returnsSentinel() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(hits: [], status: .notIndexed)
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-notindexed",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.payload == BookContextResponder.coldStartSentinel)
    }

    @Test
    func indexNotReadyThrow_returnsSentinel() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        // status .ready but search throws .indexNotReady — exercises the
        // catch arm separately from the status gate.
        let stub = StubBookSearch(hits: [], status: .ready)
        stub.setError(.indexNotReady)
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-throw",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.payload == BookContextResponder.coldStartSentinel)
    }

    @Test
    func underlyingSearchError_returnsFailureMessage() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(hits: [], status: .ready)
        stub.setError(.underlying(message: "usearch read failed"))
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-underlying",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        // A real search failure (not a not-ready index) tells the agent to
        // inform the user it couldn't retrieve the book context.
        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.payload == BookContextResponder.lookupFailedMessage)
    }

    @Test
    func unknownTool_isIgnored() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-unknown",
            name: "endConversation",
            argumentsJSON: "{}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        #expect(fake.sentToolResultsSnapshot().isEmpty)
    }

    @Test
    func badJSONArgs_returnsFailureMessage() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-bad-json",
            name: "bookContext",
            argumentsJSON: "not json"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.payload == BookContextResponder.lookupFailedMessage)
    }

    @Test
    func searchTimeout_returnsFailureMessage() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        // A search that never returns — exercises the timeout path.
        let hanging = HangingSearch()
        let responder = BookContextResponder(
            client: fake,
            search: hanging,
            bookId: UUID(),
            timeoutSeconds: 0.2
        )
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        defer { consumeTask.cancel() }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-timeout",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"something to look up\"}"
        ))

        // Wait past the 0.2s budget.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "c-timeout")
        #expect(sent.first?.payload == BookContextResponder.lookupTimedOutMessage)
    }

    @Test
    func jsonShape_onlyContainsTextPageScore() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [
                BookSearchHit(text: "passage one", page: 7, score: 0.42),
            ],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-shape",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        let payloadData = Data((sent.first?.payload ?? "").utf8)
        let parsed = try JSONSerialization.jsonObject(with: payloadData) as? [[String: Any]]
        #expect(parsed?.count == 1)
        let first = parsed?.first ?? [:]
        // Exact key set: no bookId, no chunkId, no distance.
        let keys = Set(first.keys)
        #expect(keys == Set(["text", "page", "score"]))
        #expect(first["text"] as? String == "passage one")
        #expect(first["page"] as? Int == 7)
    }

    @Test
    func searchReceivesDecodedQueryText() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookId = UUID()
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: bookId)
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-args",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"why is the sky blue?\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        #expect(stub.lastQuery() == "why is the sky blue?")
        #expect(stub.lastBookId() == bookId)
        #expect(stub.searchCallCount() == 1)
    }
}

/// `BookSearch` stub whose `search` never returns until cancelled — used to
/// drive `BookContextResponder`'s lookup-timeout path. Reports `.ready` so the
/// status gate is passed and the timeout (not the cold-start sentinel) fires.
private actor HangingSearch: BookSearch {
    func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit] {
        try await Task.sleep(nanoseconds: 60_000_000_000) // 60s — far past any test budget
        return []
    }

    func status(bookId: UUID) async -> BookSearchStatus { .ready }
}
