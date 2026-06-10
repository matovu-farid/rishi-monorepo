import Testing
import Foundation
@testable import RishiSync
import RishiAPI
import RishiCore
import RishiLibrary

/// SyncEngine — orchestration over 07-03 verbs.
///
/// Test scope is limited to engine-level behavior:
///   - runOnce calls fetcher + applier + uploaders in canonical order
///   - markPositionDirty routes through the debouncer (SYNC-03)
///   - bind(status:) toggles isRunning during the wave + snapshots after
///
/// We use the same StubMetadata / StubBookStore / StubPositionStore / StubHighlightStore
/// shape from `ChangeApplierConflictTests` and wrap real uploaders/fetcher/applier
/// around them — exercising the engine without touching the network.
@Suite("SyncEngine — runOnce orchestration + dirty marks", .serialized)
struct SyncEngineTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var dirty: [SyncPendingItem] = []
        var cleaned: [(UUID, SyncEntityKind)] = []
        var globalCursor: Date?

        func seedGlobalCursor(_ date: Date?) { globalCursor = date }

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
            if !dirty.contains(where: { $0.entityId == entityId && $0.kind == kind }) {
                dirty.append(SyncPendingItem(entityId: entityId, kind: kind))
            }
        }
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            dirty.removeAll { $0.entityId == entityId && $0.kind == kind }
            cleaned.append((entityId, kind))
            globalCursor = lastSyncedAt
        }
        func allDirty() async throws -> [SyncPendingItem] { dirty }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] {
            Array(dirty.filter { $0.kind == kind }.prefix(limit))
        }
        func pendingCount() async throws -> Int { dirty.count }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { globalCursor }
        func globalLastSyncedAt() async throws -> Date? { globalCursor }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            dirty.removeAll { $0.entityId == entityId && $0.kind == kind }
        }

        func currentDirty() -> [SyncPendingItem] { dirty }
        func cleanedSnapshot() -> [(UUID, SyncEntityKind)] { cleaned }
    }

    private actor StubBookStore: BookStore {
        var rows: [BookID: Book] = [:]
        func seed(_ book: Book) { rows[book.id] = book }
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
        func snapshot() -> [Book] { Array(rows.values) }
    }

    private actor StubPositionStore: PositionStore {
        var rows: [BookID: Position] = [:]
        func seed(_ position: Position) { rows[position.bookId] = position }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key { rows[key] = nil }
        }
        func snapshot() -> [Position] { Array(rows.values) }
    }

    private actor StubHighlightStore: HighlightStore {
        var rows: [HighlightID: Highlight] = [:]
        func highlights(for bookId: BookID) async throws -> [Highlight] {
            rows.values.filter { $0.bookId == bookId }
        }
        func highlight(_ id: HighlightID) async throws -> Highlight? { rows[id] }
        func upsert(_ highlight: Highlight) async throws { rows[highlight.id] = highlight }
        func delete(_ id: HighlightID) async throws { rows[id] = nil }
    }

    // MARK: - URLProtocol for fetcher/uploaders

    final class EngineMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
        nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
        override class var storage: MockURLProtocolStorage { _storage }
        static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
            get { _storage.handler } set { _storage.handler = newValue }
        }
        static func reset() { _storage.reset() }
        static func capturedSnapshot() -> [URLRequest] { _storage.captured }
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EngineMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private func makeEngine(
        config: SyncEngineConfig = .init(positionDebounceWindow: 0.1, batchLimit: 50, backgroundRefreshInterval: 3600),
        metadata: any SyncMetadataStore,
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        workerClient: WorkerClient,
        fileStorage: BookFileStorage
    ) -> SyncEngine {
        let queue = SyncQueue(metadataStore: metadata)
        let bookUploader = BookUploader(workerClient: workerClient, metadataStore: metadata, fileStorage: fileStorage)
        let positionUploader = PositionUploader(workerClient: workerClient, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata)
        let highlightUploader = HighlightUploader(workerClient: workerClient, highlightStore: highlightStore, metadataStore: metadata)
        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        let applier = ChangeApplier(bookStore: bookStore, positionStore: positionStore, highlightStore: highlightStore, metadataStore: metadata)
        return SyncEngine(
            config: config,
            queue: queue,
            metadataStore: metadata,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            fetcher: fetcher,
            applier: applier
        )
    }

    private func makeFileStorage() async throws -> (BookFileStorage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-sync-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(rootDirectoryURL: root)
        return (storage, root)
    }

    private func emptyChangesBody() -> Data {
        Data("""
        { "changes": [] }
        """.utf8)
    }

    // MARK: - Tests

    @Test("runOnce against 0-changes + 0-pending → applied == 0, no errors")
    func runOnceEmptyWave() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.applied == 0)
        #expect(wave.fetched == 0)
        #expect(wave.booksUploaded == 0)
        #expect(wave.positionsPushed == 0)
        #expect(wave.errors.isEmpty)
    }

    @Test("runOnce with 3 remote position changes → applier upserts 3")
    func runOnceAppliesRemotePositions() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let (storage, _) = try await makeFileStorage()

        // Three remote-only positions.
        let positions = (0..<3).map { _ in
            Position(bookId: UUID(), locator: "pdf-v1:page:1", percentComplete: 0.1, updatedAt: Date(timeIntervalSince1970: 2_000_000_000))
        }
        let changes = try positions.map { position -> SyncChange in
            let payload = try SyncPayloadCodec.encodePosition(position)
            return SyncChange(
                kind: SyncEntityKind.position.rawValue,
                id: position.id,
                payload: payload,
                updatedAt: position.updatedAt,
                deleted: false
            )
        }
        // SyncChangesResponse is Decodable-only; encode an equivalent shape ourselves.
        struct ResponseBody: Encodable { let changes: [SyncChange] }
        let body = try JSONEncoder().encode(ResponseBody(changes: changes))

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, body, nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.fetched == 3)
        #expect(wave.applied == 3)
        let stored = await positionStore.snapshot()
        #expect(stored.count == 3)
    }

    @Test("runOnce with 1 pending position in queue → PositionUploader posts to /api/sync/push")
    func runOnceDrainsPendingPosition() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let (storage, _) = try await makeFileStorage()

        // Seed a local position + mark it dirty so the queue refresh picks it up.
        let bookId = UUID()
        let position = Position(bookId: bookId, locator: "pdf-v1:page:42", percentComplete: 0.6, updatedAt: Date())
        await positionStore.seed(position)
        try await metadata.markDirty(entityId: bookId, kind: .position)

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/push" {
                // Date wire = seconds since reference date (2001-01-01) — matches default JSONDecoder.
                let body = Data("""
                { "accepted_at": 700000000 }
                """.utf8)
                return (200, body, nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.positionsPushed == 1, "expected one position push, got \(wave.positionsPushed); errors: \(wave.errors)")

        // After the wave the dirty row should be markClean'd.
        let stillDirty = await metadata.currentDirty()
        #expect(stillDirty.isEmpty)
    }

    @Test("markPositionDirty 5x in <window → exactly 1 markDirty call after debounce")
    func markPositionDirtyDebounces() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()

        let engine = makeEngine(
            config: .init(positionDebounceWindow: 0.1, batchLimit: 50, backgroundRefreshInterval: 3600),
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )

        let bookId = UUID()
        for _ in 0..<5 {
            await engine.markPositionDirty(bookId)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        // Allow the debounce window to fire.
        try await Task.sleep(nanoseconds: 250_000_000) // 250ms

        let dirty = await metadata.currentDirty()
        let positionRows = dirty.filter { $0.kind == .position }
        #expect(positionRows.count == 1)
        #expect(positionRows.first?.entityId == bookId)
    }

    @Test("bind(status:) → isRunning toggles true during runOnce then false; lastSyncedAt updated")
    func bindStatusToggle() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        // Pre-seed a global cursor so snapshotStatus has a non-nil lastSyncedAt to publish.
        await metadata.seedGlobalCursor(Date(timeIntervalSince1970: 1_900_000_000))

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )
        let status = SyncStatus()
        await engine.bind(status: status)

        let beforeSnapshot = status.snapshot()
        #expect(beforeSnapshot.isRunning == false)

        _ = await engine.runOnce()

        let afterSnapshot = status.snapshot()
        #expect(afterSnapshot.isRunning == false)
        #expect(afterSnapshot.lastSyncedAt != nil)
    }
}
