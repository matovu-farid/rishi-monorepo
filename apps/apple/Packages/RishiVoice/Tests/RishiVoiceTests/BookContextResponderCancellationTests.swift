import Testing
import Foundation
@testable import RishiVoice
import RishiSearch

/// Cancellation semantics for `BookContextResponder`. The CONTEXT.md decision
/// for Phase 25 is: a cancelled query MUST NOT write a tool result back to
/// the realtime peer — a phantom result mid-teardown is worse than no result.
///
/// Two failure modes covered:
///   1. Cancellation BEFORE the consume loop pulls the injected event off the
///      stream — exercised by cancelling the Task and then injecting (the
///      `if Task.isCancelled { return }` guard at the loop head catches it).
///   2. Cancellation BETWEEN search completion and `sendToolResult` — uses a
///      deliberately-delayed `BookSearch` stub so the test can cancel while
///      `await search.search(...)` is suspended. Verified by an empty
///      `sentToolResultsSnapshot()` after a long drain window.
@Suite("BookContextResponder cancellation")
struct BookContextResponderCancellationTests {

    @Test
    func cancellationBeforeConsume_doesNotFireSendToolResult() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())

        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        consumeTask.cancel()
        // Inject AFTER cancel — replay-on-subscribe semantics in
        // FakeRealtimeClient mean the event still hits the stream, but the
        // loop's Task.isCancelled gate at the top of each iteration drops it.
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-pre",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.sentToolResultsSnapshot().isEmpty)
    }

    @Test
    func cancellationMidSearch_skipsSendToolResult() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let search = DelayingSearch(hits: [BookSearchHit(text: "a", page: 1, score: 0.5)])
        let responder = BookContextResponder(client: fake, search: search, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-mid",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        // The delaying search sleeps 200ms inside search(). Cancel halfway
        // through, then wait long enough for any erroneous send to land.
        try await Task.sleep(nanoseconds: 80_000_000)
        consumeTask.cancel()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(fake.sentToolResultsSnapshot().isEmpty)
    }

    @Test
    func cancellationAfterSuccessfulSend_priorResultRemainsRecorded() async throws {
        // Sanity check that the cancellation gate is a tail behavior — once a
        // result HAS been sent, cancelling the responder doesn't retroactively
        // unsend it. Guards against an over-eager refactor that mutates
        // sentToolResults on cancel.
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let stub = StubBookSearch(
            hits: [BookSearchHit(text: "x", page: 1, score: 0.5)],
            status: .ready
        )
        let responder = BookContextResponder(client: fake, search: stub, bookId: UUID())
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c-ok",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))
        try await Task.sleep(nanoseconds: 150_000_000)
        consumeTask.cancel()

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "c-ok")
    }
}

// MARK: - Test fixtures

/// `BookSearch` stub that introduces a deliberate `Task.sleep` inside
/// `search(queryText:bookId:)` so the test can race a Task cancellation
/// against the search call. Status is forced to `.ready` so the responder
/// gets past the status gate and into the search arm.
private actor DelayingSearch: BookSearch {
    let hits: [BookSearchHit]

    init(hits: [BookSearchHit]) {
        self.hits = hits
    }

    func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit] {
        try await Task.sleep(nanoseconds: 200_000_000)
        return hits
    }

    func status(bookId: UUID) async -> BookSearchStatus { .ready }
}
