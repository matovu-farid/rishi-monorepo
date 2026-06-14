import Testing
import Foundation
@testable import RishiVoice
import RishiSearch

/// End-to-end RAG pipeline integration coverage (Phase 25-12).
///
/// These tests exercise the full loop with NO mocks of the search layer:
///
///   real `IdentityEmbedder` (Plan 25-04)
///     -> real `IndexBuilder` (Plan 25-05) building a small in-memory book index
///     -> real `USearchBookSearch` actor querying that index
///     -> real `BookContextResponder` (Plan 25-09)
///     -> `FakeRealtimeClient` (Plan 25-07) for the WebRTC peer
///
/// The whole point is to verify the components compose end-to-end —
/// unit tests in each prior plan cover their own surface; THIS plan proves
/// the parts compose into the goal: "the assistant can call
/// bookContext(queryText) during a voice session, receive top-N relevant
/// passages with page numbers, gracefully degrade to the cold-start sentinel
/// when the index isn't ready."
///
/// Each test uses a per-test temporary directory for the per-book index
/// files and cleans up after itself.
@Suite("RAG pipeline end-to-end (Phase 25-12)")
struct RAGPipelineIntegrationTests {

    // MARK: - Real index -> Responder -> sendToolResult round trip

    @Test
    func realIndexThroughResponderToSendToolResult() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookId = UUID()
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: tempDir, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [
                (page: 1, text: "alpha is a Greek letter"),
                (page: 2, text: "beta is the second letter"),
                (page: 3, text: "gamma is the third letter"),
            ]
        )

        let search = USearchBookSearch(rootURL: tempDir, embedder: embedder, k: 3)
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let responder = BookContextResponder(client: fake, search: search, bookId: bookId)

        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        defer { consumeTask.cancel() }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c1",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"alpha is a Greek letter\"}"
        ))

        try await waitForCondition(timeoutSeconds: 2.0) {
            !fake.sentToolResultsSnapshot().isEmpty
        }

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.callId == "c1")

        let payload = sent.first?.payload ?? ""
        let parsed = try JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        ) as? [[String: Any]]
        #expect(parsed != nil, "payload must be a JSON array of objects")
        #expect((parsed?.count ?? 0) >= 1, "expected at least one hit")

        // The hash-based IdentityEmbedder makes the query string closest to
        // itself, so the top hit must be the alpha paragraph (page 1).
        let top = parsed?.first ?? [:]
        #expect((top["text"] as? String)?.contains("alpha") == true)
        #expect(top["page"] as? Int == 1)
        // Exact key set: no bookId, no chunkId, no distance.
        #expect(Set(top.keys) == Set(["text", "page", "score"]))
    }

    // MARK: - Cold-start sentinel via real status sidecar manipulation

    @Test
    func indexingStateReturnsSentinel() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookId = UUID()
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: tempDir, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: "alpha")]
        )

        // Force the status sidecar back to .indexing. Uses the now-public
        // BookIndexLocator + IndexStatusStore (promoted to public for the
        // Phase 25-12 integration tests — see SUMMARY deviations).
        let locator = BookIndexLocator(rootURL: tempDir)
        let store = IndexStatusStore(url: locator.statusURL(bookId))
        try store.write(.indexing(chunksDone: 0, chunksTotal: 10))

        let search = USearchBookSearch(rootURL: tempDir, embedder: embedder, k: 3)
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let responder = BookContextResponder(client: fake, search: search, bookId: bookId)
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }
        defer { consumeTask.cancel() }

        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c2",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"x\"}"
        ))

        try await waitForCondition(timeoutSeconds: 2.0) {
            !fake.sentToolResultsSnapshot().isEmpty
        }

        let sent = fake.sentToolResultsSnapshot()
        #expect(sent.count == 1)
        // Verbatim cold-start sentinel — no JSON array.
        #expect(sent.first?.payload == BookContextResponder.coldStartSentinel)
    }

    // MARK: - Cancellation prevents any tool result from landing

    @Test
    func cancelStopsAllOutput() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookId = UUID()
        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: tempDir, embedder: embedder)
        try await builder.buildIndex(
            bookId: bookId,
            paragraphs: [(page: 1, text: "alpha")]
        )

        let search = USearchBookSearch(rootURL: tempDir, embedder: embedder, k: 3)
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub")
        let responder = BookContextResponder(client: fake, search: search, bookId: bookId)
        let consumeTask = Task { await responder.consume(stream: fake.toolCallStream()) }

        // Cancel BEFORE injecting — replay-on-subscribe semantics of the fake
        // mean the event will still be delivered, but the loop's
        // `Task.isCancelled` gate at the top of `consume` drops it before
        // `handle()` runs.
        consumeTask.cancel()
        fake.inject(toolCall: RealtimeToolCallEvent(
            callId: "c3",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"alpha\"}"
        ))
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        #expect(fake.sentToolResultsSnapshot().isEmpty)
    }

    // MARK: - Helpers

    /// Create a fresh per-test temp directory under the system temp root.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-25-12-\(UUID().uuidString)", isDirectory: true)
    }

    /// Poll `check` every 20 ms until it returns true or the timeout elapses.
    /// Does NOT throw on timeout — assertions in the caller will catch a
    /// stuck pipeline. Polling shape mirrors Phase 24's orthogonality test.
    private func waitForCondition(
        timeoutSeconds: Double,
        _ check: @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !check() {
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }
}
