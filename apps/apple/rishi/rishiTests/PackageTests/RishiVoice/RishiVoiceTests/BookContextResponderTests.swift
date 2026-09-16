@testable import rishi
import Testing
import Foundation




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
@Suite("BookContextResponder", .serialized)
struct BookContextResponderTests {

    @Test("chapterIndex returns a ready structured JSON result for empty arguments")
    func chapterIndex_readyResponse() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let persistence = ResponderChapterIndexPersistence(index: ChapterIndex(
            bookID: bookID,
            contentVersion: "v1",
            status: .ready,
            modelIdentifier: "test",
            modelVersion: "1",
            progress: .init(completed: 1, total: 1),
            chapters: [.init(id: "c1", name: "One", summary: "Summary")]
        ))
        let coordinator = ChapterIndexCoordinator(
            persistence: persistence,
            source: ResponderChapterSource(),
            summarizer: ResponderChapterSummarizer()
        )
        let search = StubBookSearch(
            hits: [BookSearchHit(text: "existing", page: 1, score: 1)],
            status: .ready
        )
        let responder = BookContextResponder(
            client: fake,
            search: search,
            bookId: bookID,
            chapterIndexCoordinator: coordinator,
            chapterIndexContentVersion: "v1"
        )
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "chapter-ready",
            name: "chapterIndex",
            argumentsJSON: "{}"
        ))
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "book-context-still-works",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"existing behavior\"}"
        ))
        try await Task.sleep(nanoseconds: 150_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 2)
        let chapterResult = try #require(sent.first(where: { $0.callId == "chapter-ready" }))
        let json = try #require(JSONSerialization.jsonObject(with: Data(chapterResult.payload.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "ready")
        #expect(json["bookId"] as? String == bookID.uuidString)
        #expect(json["contentVersion"] as? String == "v1")
        #expect((json["chapters"] as? [[String: Any]])?.first?["summary"] as? String == "Summary")
        #expect(json["totalChapters"] as? Int == 1)
        #expect(json["nextStartChapter"] == nil)
        #expect(Set(json.keys) == Set(["status", "bookId", "contentVersion", "chapters", "totalChapters"]))
        let bookContextResult = try #require(sent.first(where: { $0.callId == "book-context-still-works" }))
        #expect((try JSONSerialization.jsonObject(with: Data(bookContextResult.payload.utf8)) as? [[String: Any]])?.first?["text"] as? String == "existing")
    }

    @Test("chapterIndex default page returns a cursor without omitting page chapters")
    func chapterIndex_defaultPageReturnsNextCursor() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(index: responderIndex(bookID: bookID, count: 20)),
            source: ResponderChapterSource(),
            summarizer: ResponderChapterSummarizer()
        )
        let responder = BookContextResponder(client: fake, bookId: bookID, chapterIndexCoordinator: coordinator, chapterIndexContentVersion: "v1")
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-page-default", name: "chapterIndex", argumentsJSON: "{}"))
        try await Task.sleep(nanoseconds: 500_000_000)
        consumeTask.cancel()

        let sent = try #require(fake.sentToolResultsSnapshot().first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent.payload.utf8)) as? [String: Any])
        let chapters = try #require(json["chapters"] as? [[String: Any]])
        #expect(chapters.count == 16)
        #expect(chapters.first?["id"] as? String == "c0")
        #expect(chapters.last?["id"] as? String == "c15")
        #expect(json["totalChapters"] as? Int == 20)
        #expect(json["nextStartChapter"] as? Int == 16)
    }

    @Test("chapterIndex explicit page starts at the requested cursor")
    func chapterIndex_explicitPageUsesStartAndMax() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(index: responderIndex(bookID: bookID, count: 20)),
            source: ResponderChapterSource(),
            summarizer: ResponderChapterSummarizer()
        )
        let responder = BookContextResponder(client: fake, bookId: bookID, chapterIndexCoordinator: coordinator, chapterIndexContentVersion: "v1")
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-page-explicit", name: "chapterIndex", argumentsJSON: "{\"startChapter\":16,\"maxChapters\":4}"))
        try await Task.sleep(nanoseconds: 500_000_000)
        consumeTask.cancel()

        let sent = try #require(fake.sentToolResultsSnapshot().first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent.payload.utf8)) as? [String: Any])
        let chapters = try #require(json["chapters"] as? [[String: Any]])
        #expect(chapters.map { $0["id"] as? String } == ["c16", "c17", "c18", "c19"])
        #expect(json["totalChapters"] as? Int == 20)
        #expect(json["nextStartChapter"] == nil)
    }

    @Test("chapterIndex rejects an oversized page request with bounded failure JSON")
    func chapterIndex_oversizedPageRequestFailsBoundedly() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(index: responderIndex(bookID: bookID, count: 20)),
            source: ResponderChapterSource(),
            summarizer: ResponderChapterSummarizer()
        )
        let responder = BookContextResponder(client: fake, bookId: bookID, chapterIndexCoordinator: coordinator, chapterIndexContentVersion: "v1")
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-page-overflow", name: "chapterIndex", argumentsJSON: "{\"maxChapters\":17}"))
        try await Task.sleep(nanoseconds: 500_000_000)
        consumeTask.cancel()

        let sent = try #require(fake.sentToolResultsSnapshot().first)
        #expect(sent.payload.utf8.count <= 64 * 1024)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent.payload.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "failed")
        #expect((json["chapters"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("chapterIndex returns a bounded failed structured JSON result")
    func chapterIndex_failedResponseIsBounded() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(),
            source: ResponderChapterSource(),
            summarizer: ResponderFailingSummarizer()
        )
        let responder = BookContextResponder(client: fake, bookId: bookID, chapterIndexCoordinator: coordinator, chapterIndexContentVersion: "v1")
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-failed", name: "chapterIndex", argumentsJSON: "{}"))
        try await Task.sleep(nanoseconds: 500_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent[0].payload.utf8.count <= 64 * 1024)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent[0].payload.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "failed")
        #expect(json["bookId"] as? String == bookID.uuidString)
        #expect(((json["error"] as? String)?.count ?? 0) <= 512)
    }

    @Test("chapterIndex returns building after the coordinator timeout")
    func chapterIndex_timeoutReturnsBuilding() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(),
            source: ResponderChapterSource(),
            summarizer: ResponderBlockingSummarizer(),
            timeout: .milliseconds(10)
        )
        let responder = BookContextResponder(
            client: fake,
            bookId: bookID,
            chapterIndexCoordinator: coordinator,
            chapterIndexContentVersion: "v1"
        )
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-building", name: "chapterIndex", argumentsJSON: "{}"))
        try await Task.sleep(nanoseconds: 500_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent[0].payload.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "building")
    }

    @Test("chapterIndex returns unavailable when no chapter source exists")
    func chapterIndex_unavailableResponse() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let bookID = UUID()
        let coordinator = ChapterIndexCoordinator(
            persistence: ResponderChapterIndexPersistence(),
            source: ResponderChapterSource(availability: .unavailable(diagnostics: ["no outline"])),
            summarizer: ResponderChapterSummarizer()
        )
        let responder = BookContextResponder(client: fake, bookId: bookID, chapterIndexCoordinator: coordinator, chapterIndexContentVersion: "v1")
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        fake.inject(toolCall: RealtimeToolCallEvent(callId: "chapter-unavailable", name: "chapterIndex", argumentsJSON: "{}"))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(sent[0].payload.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "unavailable")
    }

    @Test("user-facing lookup messages hide internal retrieval details")
    func userFacingMessagesHideImplementationDetails() {
        let messages = [
            BookContextResponder.coldStartSentinel,
            BookContextResponder.lookupFailedMessage,
            BookContextResponder.lookupTimedOutMessage,
        ].map { $0.lowercased() }

        for message in messages {
            #expect(!message.contains("tool"))
            #expect(!message.contains("context"))
            #expect(!message.contains("index"))
            #expect(!message.contains("lookup"))
        }
    }

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
    func failedIndexStatus_returnsFailureMessageAndLogsReason() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(hits: [], status: .failed(reason: "SQLite error 10: disk I/O error"))
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())

        let events = LogEventBox()
        Log._testCapture.handler = { name, level, data in
            events.append(name: name, level: level, data: data)
        }
        defer { Log._testCapture.reset() }

        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-failed-status",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.payload == BookContextResponder.lookupFailedMessage)

        let recorded = events.snapshot()
        let sawFailedStatusLog = recorded.contains { event in
            event.name == "voice.tool.status.failed"
            && event.level == .error
            && event.data?["reason"] == "SQLite error 10: disk I/O error"
        }
        let sawFailureSentLog = recorded.contains { event in
            event.name == "voice.tool.error.sent"
            && event.data?["reason"] == "status_failed"
        }
        #expect(sawFailedStatusLog)
        #expect(sawFailureSentLog)
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

/// Thread-safe collector for `Log._testCapture` notifications in this suite.
private final class LogEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, level: LogLevel, data: [String: String]?)] = []

    func append(name: String, level: LogLevel, data: [String: String]?) {
        lock.lock(); defer { lock.unlock() }
        events.append((name: name, level: level, data: data))
    }

    func snapshot() -> [(name: String, level: LogLevel, data: [String: String]?)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

private actor ResponderChapterIndexPersistence: ChapterIndexPersistence {
    private var stored: ChapterIndex?

    init(index: ChapterIndex? = nil) { stored = index }

    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? {
        guard stored?.bookID == bookID, stored?.contentVersion == contentVersion else { return nil }
        return stored
    }

    func upsertChapterIndex(_ index: ChapterIndex) async throws { stored = index }
}

private func responderIndex(bookID: BookID, count: Int) -> ChapterIndex {
    ChapterIndex(
        bookID: bookID,
        contentVersion: "v1",
        status: .ready,
        modelIdentifier: "test",
        modelVersion: "1",
        progress: .init(completed: count, total: count),
        chapters: (0..<count).map { index in
            .init(id: "c\(index)", name: "Chapter \(index)", summary: "Summary \(index)")
        }
    )
}

private struct ResponderChapterSource: ChapterSource {
    let availability: ChapterSourceResult.Availability

    init(availability: ChapterSourceResult.Availability = .available) { self.availability = availability }

    func chapters() async -> ChapterSourceResult {
        ChapterSourceResult(
            availability: availability,
            records: [ChapterSourceRecord(id: "c1", name: "One", locator: .epub(href: "one.xhtml"), text: "text")]
        )
    }
}

private struct ResponderChapterSummarizer: ChapterSummarizing {
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        .init(id: chapter.id, name: chapter.name, summary: "Summary")
    }
}

private struct ResponderBlockingSummarizer: ChapterSummarizing {
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        try await Task.sleep(for: .seconds(5))
        return .init(id: chapter.id, name: chapter.name, summary: "Summary")
    }
}

private struct ResponderFailingSummarizer: ChapterSummarizing {
    func summarize(chapter: ChapterSourceRecord) async throws -> ChapterSummary {
        throw ResponderChapterIndexError.failed
    }
}

private enum ResponderChapterIndexError: Error {
    case failed
}
