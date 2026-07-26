@testable import rishi
import Testing
import Foundation




/// SYNC-03 — PositionUploader: drain pending positions → POST /api/sync/push → markClean.
@Suite("PositionUploader", .serialized)
struct PositionUploaderTests {

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
        func cleanCount() -> Int { cleanCalls.count }
        func cleanCursors() -> [Date] { cleanCalls.map(\.2) }
    }

    private actor StubPositionStore: PositionStore {
        private var rows: [BookID: Position] = [:]

        func seed(_ rows: [Position]) {
            for r in rows { self.rows[r.bookId] = r }
        }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key {
                rows[key] = nil
            }
        }
    }

    private actor StubBookStore: BookStore {
        func books(for userId: UserID) async throws -> [Book] { [] }
        func book(_ id: BookID) async throws -> Book? { nil }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PositionUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private let acceptedAtUnix: TimeInterval = 1_780_000_000

    // MARK: - Tests

    @Test("Happy path: one pending position → one POST /api/sync/push → markClean with response cursor")
    func happyPath() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let bookStore = StubBookStore()

        let bookId = UUID()
        let position = Position(
            id: UUID(),
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await positionStore.seed([position])

        // Reference-date offset = unix - 978307200
        let acceptedAtRef = acceptedAtUnix - 978_307_200
        PositionUploaderMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/push")
            #expect(request.httpMethod == "POST")
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: bookId, kind: .position),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [bookId])
        let cursors = await metadata.cleanCursors()
        #expect(cursors.first?.timeIntervalSince1970 == acceptedAtUnix)
    }

    @Test("Empty input → 0 pushed, no HTTP call issued")
    func emptyInputDoesNothing() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let bookStore = StubBookStore()
        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        PositionUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
    }

    @Test("Missing local row → markClean drained, not sent in body, returns 0 live")
    func missingLocalRowDrained() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore() // empty
        let bookStore = StubBookStore()

        let missingBookId = UUID()
        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        // No HTTP should fire — all items are stale.
        PositionUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingBookId, kind: .position),
        ])

        #expect(pushed == 0)
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        // Drained row should have been markClean'd so the queue stops surfacing it.
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [missingBookId])
    }
}
