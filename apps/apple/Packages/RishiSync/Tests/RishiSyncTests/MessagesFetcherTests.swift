import Testing
import Foundation
@testable import RishiSync
import RishiCore
import RishiCore

/// Phase 16-05 — MessagesFetcher: pull /api/sync/messages?since=<ms>.
///
/// Mirrors the ConversationsFetcher posture. Messages have no sentinel
/// fields — `conversation_id` is the only FK and is NOT nullable on the wire.
@Suite("MessagesFetcher", .serialized)
struct MessagesFetcherTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var watermark: Date?
        var kindCalls: Int = 0

        init(watermark: Date? = nil) { self.watermark = watermark }

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {}
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? {
            kindCalls += 1
            return watermark
        }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}

        func callsToKind() -> Int { kindCalls }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MessagesFetcherMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private func rowsBody(_ rows: [String]) -> Data {
        let joined = rows.joined(separator: ",")
        return Data("""
        { "rows": [\(joined)] }
        """.utf8)
    }

    // MARK: - Tests

    @Test("Nil watermark → endpoint path is /api/sync/messages without ?since=")
    func nilWatermarkOmitsSince() async throws {
        MessagesFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata(watermark: nil)

        MessagesFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.isEmpty)

        let captured = MessagesFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        let abs = captured[0].url?.absoluteString ?? ""
        #expect(abs.contains("/api/sync/messages"))
        #expect(!abs.contains("since="))
        let calls = await metadata.callsToKind()
        #expect(calls == 1)
    }

    @Test("Set watermark → path includes ?since=<ms_epoch>")
    func watermarkAppendedAsSinceQuery() async throws {
        MessagesFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let watermark = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = StubMetadata(watermark: watermark)

        MessagesFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        _ = try await fetcher.fetch()

        let captured = MessagesFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        let abs = captured[0].url?.absoluteString ?? ""
        #expect(abs.contains("/api/sync/messages"))
        #expect(abs.contains("since=1700000000000"))
    }

    @Test("Two rows → returns 2 Message values with correctly mapped fields")
    func twoRowsDecode() async throws {
        MessagesFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        let m1Id = UUID()
        let m2Id = UUID()
        let convoId = UUID()
        let row1 = """
        {
            "id": "\(m1Id.uuidString)",
            "conversation_id": "\(convoId.uuidString)",
            "role": "user",
            "content": "Hello",
            "created_at": 1700000000000,
            "updated_at": 1700000000000
        }
        """
        let row2 = """
        {
            "id": "\(m2Id.uuidString)",
            "conversation_id": "\(convoId.uuidString)",
            "role": "assistant",
            "content": "Hi back",
            "created_at": 1700000005000,
            "updated_at": 1700000005000
        }
        """

        MessagesFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([row1, row2]), nil)
        }

        let fetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.count == 2)
        #expect(result[0].id == m1Id)
        #expect(result[0].conversationId == convoId)
        #expect(result[0].role == .user)
        #expect(result[0].content == "Hello")
        #expect(result[0].createdAt.timeIntervalSince1970 == 1_700_000_000)
        #expect(result[1].id == m2Id)
        #expect(result[1].role == .assistant)
        #expect(result[1].content == "Hi back")
    }

    @Test("Empty rows response → returns []")
    func emptyRowsReturnsEmpty() async throws {
        MessagesFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        MessagesFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.isEmpty)
    }

    @Test("401 → throws")
    func unauthorizedThrows() async throws {
        MessagesFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        MessagesFetcherMockURLProtocol.handler = { _ in
            (401, Data("""
            { "error": { "code": "UNAUTHENTICATED", "message": "missing" } }
            """.utf8), nil)
        }

        let fetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.fetch()
        }
    }
}
