import Testing
import Foundation
@testable import RishiSync
import RishiCore
import RishiCore

/// Phase 16-04 — ConversationUploader: drain pending conversations
/// -> POST /api/sync/conversations -> markClean. Mirrors PositionUploader.
@Suite("ConversationUploader", .serialized)
struct ConversationUploaderTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []
        var forgetCalls: [(UUID, SyncEntityKind)] = []

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
        }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            forgetCalls.append((entityId, kind))
        }

        func cleanedIds() -> [UUID] { cleanCalls.map(\.0) }
        func cleanedKinds() -> [SyncEntityKind] { cleanCalls.map(\.1) }
        func cleanCount() -> Int { cleanCalls.count }
    }

    private actor StubConversationStore: ConversationStore {
        private var rows: [ConversationID: Conversation] = [:]

        func seed(_ rows: [Conversation]) {
            for r in rows { self.rows[r.id] = r }
        }
        func conversations(for userId: UserID) async throws -> [Conversation] {
            rows.values.filter { $0.userId == userId }
        }
        func conversation(_ id: ConversationID) async throws -> Conversation? { rows[id] }
        func upsert(_ conversation: Conversation) async throws { rows[conversation.id] = conversation }
        func delete(_ id: ConversationID) async throws { rows.removeValue(forKey: id) }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConversationUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private func okResponseBody(appliedCount: Int) -> Data {
        Data("""
        { "applied_count": \(appliedCount) }
        """.utf8)
    }

    // MARK: - Tests

    @Test("Happy path: one pending conversation -> POST /api/sync/conversations -> markClean")
    func happyPath() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore()

        let userId = UUID()
        let bookId = UUID()
        let convo = Conversation(
            id: UUID(),
            userId: userId,
            bookId: bookId,
            title: "About this book",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        await store.seed([convo])

        ConversationUploaderMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/conversations")
            #expect(request.httpMethod == "POST")
            return (200, self.okResponseBody(appliedCount: 1), nil)
        }

        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: convo.id, kind: .conversation),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [convo.id])
        let kinds = await metadata.cleanedKinds()
        #expect(kinds == [.conversation])
    }

    @Test("Empty input -> 0 pushed, no HTTP call")
    func emptyInputDoesNothing() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore()

        ConversationUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(ConversationUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        let count = await metadata.cleanCount()
        #expect(count == 0)
    }

    @Test("Missing local row -> markClean drained, no HTTP, returns 0")
    func missingLocalRowDrained() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore() // empty

        ConversationUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let missingId = UUID()
        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingId, kind: .conversation),
        ])

        #expect(pushed == 0)
        #expect(ConversationUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [missingId])
    }

    @Test("401 surfaces error, no markClean")
    func authFailureSurfacesError() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore()

        let convo = Conversation(
            userId: UUID(),
            title: "X",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([convo])

        ConversationUploaderMockURLProtocol.handler = { _ in
            (401, Data("""
            { "error": { "code": "unauthorized", "message": "no token" } }
            """.utf8), nil)
        }

        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )

        await #expect(throws: (any Error).self) {
            _ = try await uploader.pushPending(items: [
                SyncQueueItem(entityId: convo.id, kind: .conversation),
            ])
        }
        let cleaned = await metadata.cleanCount()
        #expect(cleaned == 0)
    }

    @Test("5xx surfaces error, no markClean — item stays dirty for retry")
    func serverErrorSurfacesError() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore()

        let convo = Conversation(
            userId: UUID(),
            title: "X",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([convo])

        ConversationUploaderMockURLProtocol.handler = { _ in
            (503, Data("""
            { "error": { "code": "unavailable", "message": "down" } }
            """.utf8), nil)
        }

        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )

        await #expect(throws: (any Error).self) {
            _ = try await uploader.pushPending(items: [
                SyncQueueItem(entityId: convo.id, kind: .conversation),
            ])
        }
        let cleaned = await metadata.cleanCount()
        #expect(cleaned == 0)
    }

    @Test("bookId nil maps to sentinel UUID on the wire")
    func nilBookIdMapsToSentinel() async throws {
        ConversationUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubConversationStore()

        let convo = Conversation(
            id: UUID(),
            userId: UUID(),
            bookId: nil,
            title: "No-book chat",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([convo])

        // Capture the request body so we can decode and assert the wire shape.
        nonisolated(unsafe) var capturedBody: Data?
        ConversationUploaderMockURLProtocol.handler = { request in
            // URLProtocol exposes streamed bodies via httpBodyStream; for the
            // small JSON we POST in v1, the client sets httpBody directly.
            // Newer URLSession copies bodies onto the stream — read either.
            if let data = request.httpBody {
                capturedBody = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buf = Data()
                let cap = 4096
                let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
                defer { ptr.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(ptr, maxLength: cap)
                    if read <= 0 { break }
                    buf.append(ptr, count: read)
                }
                capturedBody = buf
            }
            return (200, self.okResponseBody(appliedCount: 1), nil)
        }

        let uploader = ConversationUploader(
            workerClient: workerClient,
            conversationStore: store,
            metadataStore: metadata
        )
        _ = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: convo.id, kind: .conversation),
        ])

        let body = try #require(capturedBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let arr = decoded?["conversations"] as? [[String: Any]]
        let row = try #require(arr?.first)
        let bookId = row["book_id"] as? String
        #expect(bookId == "00000000-0000-0000-0000-000000000000")
    }
}
