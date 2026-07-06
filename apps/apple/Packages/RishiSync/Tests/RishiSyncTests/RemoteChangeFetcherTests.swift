import Testing
import Foundation
import os
@testable import RishiSync
import RishiCore
import RishiCore

/// SYNC-02 — RemoteChangeFetcher: pull /api/sync/changes?since=<cursor>.
@Suite("RemoteChangeFetcher", .serialized)
struct RemoteChangeFetcherTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cursor: Date?
        var globalCalls = 0

        init(cursor: Date? = nil) { self.cursor = cursor }

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {}
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? {
            globalCalls += 1
            return cursor
        }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}
        func callsToGlobal() -> Int { globalCalls }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteChangeFetcherMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    // MARK: - Tests

    @Test("Nil cursor → endpoint path is /api/sync/changes without ?since=")
    func nilCursorOmitsQuery() async throws {
        RemoteChangeFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata(cursor: nil)

        RemoteChangeFetcherMockURLProtocol.handler = { _ in
            let body = """
            { "changes": [] }
            """
            return (200, Data(body.utf8), nil)
        }

        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        let changes = try await fetcher.fetch()
        #expect(changes.isEmpty)

        let captured = RemoteChangeFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        #expect(captured[0].url?.path == "/api/sync/changes")
        #expect(captured[0].url?.query == nil)
        let globalCalls = await metadata.callsToGlobal()
        #expect(globalCalls == 1)
    }

    @Test("Set cursor → path includes ?since= with the ISO8601 stamp")
    func cursorIsAppendedAsSinceQuery() async throws {
        RemoteChangeFetcherMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = StubMetadata(cursor: cursor)

        RemoteChangeFetcherMockURLProtocol.handler = { _ in
            let body = """
            { "changes": [] }
            """
            return (200, Data(body.utf8), nil)
        }

        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        _ = try await fetcher.fetch()

        let captured = RemoteChangeFetcherMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        // SyncChangesEndpoint embeds the query in the path string; the worker
        // URL preserves that as part of absoluteString. We assert on the full
        // string rather than URL.query — URLComponents tucks the URL-encoded
        // form into path when constructed via appendPath.
        let abs = captured[0].url?.absoluteString ?? ""
        #expect(abs.contains("/api/sync/changes"))
        #expect(abs.contains("since="))
        // 1_700_000_000 ≈ 2023-11-14T22:13:20Z; check year shows up.
        #expect(abs.contains("2023"))
    }
}
