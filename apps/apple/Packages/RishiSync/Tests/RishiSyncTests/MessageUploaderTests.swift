import Testing
import Foundation
@testable import RishiSync
import RishiAPI
import RishiCore

/// Phase 16-04 — MessageUploader: drain pending messages
/// -> POST /api/sync/messages -> markClean. Mirrors ConversationUploader.
@Suite("MessageUploader", .serialized)
struct MessageUploaderTests {

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

    private actor StubMessageStore: MessageStore {
        private var rows: [MessageID: Message] = [:]

        func seed(_ rows: [Message]) {
            for r in rows { self.rows[r.id] = r }
        }
        func messages(for conversationId: ConversationID) async throws -> [Message] {
            rows.values
                .filter { $0.conversationId == conversationId }
                .sorted { $0.createdAt < $1.createdAt }
        }
        func message(_ id: MessageID) async throws -> Message? { rows[id] }
        func upsert(_ message: Message) async throws { rows[message.id] = message }
        func delete(_ id: MessageID) async throws { rows.removeValue(forKey: id) }
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MessageUploaderMockURLProtocol.self]
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

    @Test("Happy path: one pending message -> POST /api/sync/messages -> markClean")
    func happyPath() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore()

        let msg = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([msg])

        MessageUploaderMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/messages")
            #expect(request.httpMethod == "POST")
            return (200, self.okResponseBody(appliedCount: 1), nil)
        }

        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: msg.id, kind: .message),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [msg.id])
        let kinds = await metadata.cleanedKinds()
        #expect(kinds == [.message])
    }

    @Test("Empty input -> 0 pushed, no HTTP call")
    func emptyInputDoesNothing() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore()

        MessageUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(MessageUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        let count = await metadata.cleanCount()
        #expect(count == 0)
    }

    @Test("Missing local row -> markClean drained, no HTTP, returns 0")
    func missingLocalRowDrained() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore() // empty

        MessageUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let missingId = UUID()
        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingId, kind: .message),
        ])

        #expect(pushed == 0)
        #expect(MessageUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [missingId])
    }

    @Test("401 surfaces error, no markClean")
    func authFailureSurfacesError() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore()

        let msg = Message(
            conversationId: UUID(),
            role: .assistant,
            content: "x",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([msg])

        MessageUploaderMockURLProtocol.handler = { _ in
            (401, Data("""
            { "error": { "code": "unauthorized", "message": "no token" } }
            """.utf8), nil)
        }

        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )

        await #expect(throws: (any Error).self) {
            _ = try await uploader.pushPending(items: [
                SyncQueueItem(entityId: msg.id, kind: .message),
            ])
        }
        let cleaned = await metadata.cleanCount()
        #expect(cleaned == 0)
    }

    @Test("5xx surfaces error, no markClean — item stays dirty for retry")
    func serverErrorSurfacesError() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore()

        let msg = Message(
            conversationId: UUID(),
            role: .user,
            content: "x",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.seed([msg])

        MessageUploaderMockURLProtocol.handler = { _ in
            (503, Data("""
            { "error": { "code": "unavailable", "message": "down" } }
            """.utf8), nil)
        }

        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )

        await #expect(throws: (any Error).self) {
            _ = try await uploader.pushPending(items: [
                SyncQueueItem(entityId: msg.id, kind: .message),
            ])
        }
        let cleaned = await metadata.cleanCount()
        #expect(cleaned == 0)
    }

    @Test("updatedAt synthesized from createdAt (local Message has no updatedAt)")
    func updatedAtSynthesizedFromCreatedAt() async throws {
        MessageUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let store = StubMessageStore()

        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        let msg = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "hello",
            createdAt: createdAt
        )
        await store.seed([msg])

        nonisolated(unsafe) var capturedBody: Data?
        MessageUploaderMockURLProtocol.handler = { request in
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

        let uploader = MessageUploader(
            workerClient: workerClient,
            messageStore: store,
            metadataStore: metadata
        )
        _ = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: msg.id, kind: .message),
        ])

        let body = try #require(capturedBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let arr = decoded?["messages"] as? [[String: Any]]
        let row = try #require(arr?.first)
        let created = row["created_at"] as? Int64 ?? Int64(row["created_at"] as? Int ?? 0)
        let updated = row["updated_at"] as? Int64 ?? Int64(row["updated_at"] as? Int ?? 0)
        let expectedMs = Int64(createdAt.timeIntervalSince1970 * 1000)
        #expect(created == expectedMs)
        #expect(updated == expectedMs)
        #expect(created == updated)
    }
}
