import Testing
import Foundation
@testable import RishiSync
import RishiCore
import RishiCore

/// Phase 16-05 — ConversationsFetcher: pull /api/sync/conversations?since=<ms>.
///
/// Mirrors the existing `RemoteChangeFetcherTests` posture (per-suite
/// MockURLProtocol subclass, `.serialized` suite). The fetcher is responsible
/// for reading the per-resource watermark from `SyncMetadataStore` and
/// mapping `ConversationRowWire` → `Conversation`, including the sentinel
/// zero-UUID `book_id` → `nil` reverse-mapping that mirrors the uploader
/// convention from Phase 16-04.
@Suite("ConversationsFetcher", .serialized)
struct ConversationsFetcherTests {

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
        config.protocolClasses = [ConversationsFetcherMockURLProtocol.self]
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

    @Test("Nil watermark → endpoint path is /api/sync/conversations without ?since=")
    func nilWatermarkOmitsSince() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata(watermark: nil)

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.isEmpty)

        let captured = ConversationsFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        let abs = captured[0].url?.absoluteString ?? ""
        #expect(abs.contains("/api/sync/conversations"))
        #expect(!abs.contains("since="))
        let calls = await metadata.callsToKind()
        #expect(calls == 1)
    }

    @Test("Set watermark → path includes ?since=<ms_epoch>")
    func watermarkAppendedAsSinceQuery() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let watermark = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = StubMetadata(watermark: watermark)

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        _ = try await fetcher.fetch()

        let captured = ConversationsFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        let abs = captured[0].url?.absoluteString ?? ""
        #expect(abs.contains("/api/sync/conversations"))
        #expect(abs.contains("since=1700000000000"))
    }

    @Test("Two rows → returns 2 Conversation values with correctly mapped fields")
    func twoRowsDecode() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        let id1 = UUID()
        let id2 = UUID()
        let userId = UUID()
        let bookId = UUID()
        let row1 = """
        {
            "id": "\(id1.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "\(bookId.uuidString)",
            "title": "First chat",
            "archived": false,
            "created_at": 1700000000000,
            "updated_at": 1700000050000
        }
        """
        let row2 = """
        {
            "id": "\(id2.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "\(bookId.uuidString)",
            "title": "Second chat",
            "archived": false,
            "created_at": 1700000100000,
            "updated_at": 1700000200000
        }
        """

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([row1, row2]), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.count == 2)
        #expect(result[0].id == id1)
        #expect(result[0].title == "First chat")
        #expect(result[0].userId == userId)
        #expect(result[0].bookId == bookId)
        #expect(result[0].createdAt.timeIntervalSince1970 == 1_700_000_000)
        #expect(result[0].updatedAt.timeIntervalSince1970 == 1_700_000_050)
        #expect(result[1].id == id2)
        #expect(result[1].title == "Second chat")
    }

    @Test("Empty rows response → returns []")
    func emptyRowsReturnsEmpty() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([]), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.isEmpty)
    }

    @Test("401 → throws")
    func unauthorizedThrows() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (401, Data("""
            { "error": { "code": "UNAUTHENTICATED", "message": "missing" } }
            """.utf8), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.fetch()
        }
    }

    @Test("Sentinel zero-UUID book_id → mapped local Conversation.bookId == nil")
    func zeroBookIdSentinelMapsToNil() async throws {
        ConversationsFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()

        let id = UUID()
        let userId = UUID()
        let row = """
        {
            "id": "\(id.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "00000000-0000-0000-0000-000000000000",
            "title": "No book",
            "archived": false,
            "created_at": 1700000000000,
            "updated_at": 1700000050000
        }
        """

        ConversationsFetcherMockURLProtocol.handler = { _ in
            (200, self.rowsBody([row]), nil)
        }

        let fetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let result = try await fetcher.fetch()
        #expect(result.count == 1)
        #expect(result[0].bookId == nil)
    }
}
