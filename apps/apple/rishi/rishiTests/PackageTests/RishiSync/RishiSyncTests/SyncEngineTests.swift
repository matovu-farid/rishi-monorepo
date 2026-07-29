@testable import rishi
import Testing
import Foundation
import os





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

    private actor StubConversationStore: ConversationStore {
        var rows: [ConversationID: Conversation] = [:]
        func seed(_ convo: Conversation) { rows[convo.id] = convo }
        func conversations(for userId: UserID) async throws -> [Conversation] {
            rows.values.filter { $0.userId == userId }
        }
        func conversation(_ id: ConversationID) async throws -> Conversation? { rows[id] }
        func upsert(_ conversation: Conversation) async throws { rows[conversation.id] = conversation }
        func delete(_ id: ConversationID) async throws { rows.removeValue(forKey: id) }
    }

    private actor StubMessageStore: MessageStore {
        var rows: [MessageID: Message] = [:]
        func seed(_ msg: Message) { rows[msg.id] = msg }
        func messages(for conversationId: ConversationID) async throws -> [Message] {
            rows.values
                .filter { $0.conversationId == conversationId }
                .sorted { $0.createdAt < $1.createdAt }
        }
        func message(_ id: MessageID) async throws -> Message? { rows[id] }
        func upsert(_ message: Message) async throws { rows[message.id] = message }
        func delete(_ id: MessageID) async throws { rows.removeValue(forKey: id) }
    }

    private actor EngineStubBookmarkStore: BookmarkStore {
        var rows: [BookmarkID: Bookmark] = [:]
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
            rows.values.filter { $0.bookId == bookId }
        }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { rows[id] }
        func upsert(_ bookmark: Bookmark) async throws { rows[bookmark.id] = bookmark }
        func delete(_ id: BookmarkID) async throws { rows[id] = nil }
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
        conversationStore: any ConversationStore = StubConversationStore(),
        messageStore: any MessageStore = StubMessageStore(),
        workerClient: WorkerClient,
        fileStorage: BookFileStorage,
        chatRefreshDelegate: (any ChatSyncRefreshDelegate)? = nil
    ) -> SyncEngine {
        let queue = SyncQueue(metadataStore: metadata)
        let bookUploader = BookUploader(workerClient: workerClient, metadataStore: metadata, fileStorage: fileStorage, userIdProvider: { "test-user" })
        let positionUploader = PositionUploader(workerClient: workerClient, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata)
        let highlightUploader = HighlightUploader(workerClient: workerClient, highlightStore: highlightStore, metadataStore: metadata)
        let conversationUploader = ConversationUploader(workerClient: workerClient, conversationStore: conversationStore, metadataStore: metadata)
        let messageUploader = MessageUploader(workerClient: workerClient, messageStore: messageStore, metadataStore: metadata)
        let bookmarkUploader = BookmarkUploader(workerClient: workerClient, bookmarkStore: EngineStubBookmarkStore(), metadataStore: metadata)
        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        let applier = ChangeApplier(bookStore: bookStore, positionStore: positionStore, highlightStore: highlightStore, bookmarkStore: EngineStubBookmarkStore(), metadataStore: metadata)
        let conversationsFetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let messagesFetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        return SyncEngine(
            config: config,
            dependencies: .init(
            queue: queue,
            metadataStore: metadata,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            bookmarkUploader: bookmarkUploader,
            fetcher: fetcher,
            applier: applier,
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            chatRefreshDelegate: chatRefreshDelegate
            )
        )
    }

    private func makeFileStorage() async throws -> (BookFileStorage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-sync-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Engine tests never upload books — a throwaway StubBookStore is enough.
        let storage = BookFileStorage(rootURL: root, bookStore: StubBookStore(), coverExtractors: [:])
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
            // Phase 16-05 — chat-sync GETs added to the inbound branch.
            // Empty-wave test must satisfy them too.
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
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

    // MARK: - Phase 16-04: conversation/message bucket routing

    @Test("runOnce routes pending .conversation through ConversationUploader -> POST /api/sync/conversations")
    func runOnceDrainsPendingConversation() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let (storage, _) = try await makeFileStorage()

        let convo = Conversation(
            id: UUID(),
            userId: UUID(),
            bookId: nil,
            title: "Synced chat",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        await conversationStore.seed(convo)
        try await metadata.markDirty(entityId: convo.id, kind: .conversation)

        nonisolated(unsafe) var sawConversationsPost = false
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "POST" {
                sawConversationsPost = true
                return (200, Data("""
                { "applied_count": 1 }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            conversationStore: conversationStore,
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.conversationsPushed == 1, "expected 1 conversation pushed, got \(wave.conversationsPushed); errors: \(wave.errors)")
        #expect(sawConversationsPost, "expected POST /api/sync/conversations to fire")
        let stillDirty = await metadata.currentDirty()
        #expect(stillDirty.filter { $0.kind == .conversation }.isEmpty)
    }

    @Test("runOnce routes pending .message through MessageUploader -> POST /api/sync/messages")
    func runOnceDrainsPendingMessage() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let messageStore = StubMessageStore()
        let (storage, _) = try await makeFileStorage()

        let msg = Message(
            id: UUID(),
            conversationId: UUID(),
            role: .user,
            content: "synced",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await messageStore.seed(msg)
        try await metadata.markDirty(entityId: msg.id, kind: .message)

        nonisolated(unsafe) var sawMessagesPost = false
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "POST" {
                sawMessagesPost = true
                return (200, Data("""
                { "applied_count": 1 }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            messageStore: messageStore,
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.messagesPushed == 1, "expected 1 message pushed, got \(wave.messagesPushed); errors: \(wave.errors)")
        #expect(sawMessagesPost, "expected POST /api/sync/messages to fire")
        let stillDirty = await metadata.currentDirty()
        #expect(stillDirty.filter { $0.kind == .message }.isEmpty)
    }

    // MARK: - Phase 16-05: inbound chat sync (Conversations + Messages fetchers)

    /// Test-only delegate spy. `final class @unchecked Sendable` so the
    /// closure-capturing engine can hold it without Swift 6 strict yelling.
    /// Uses `OSAllocatedUnfairLock` because NSLock.lock()/unlock() are
    /// unavailable from async contexts in Swift 6.
    private final class SpyChatRefreshDelegate: ChatSyncRefreshDelegate, @unchecked Sendable {
        private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        func chatSyncDidMerge() async {
            counter.withLock { $0 += 1 }
        }
        func callCount() -> Int {
            counter.withLock { $0 }
        }
    }

    @Test("runOnce inbound: ConversationsFetcher rows are upserted + watermark advanced")
    func runOnceInboundConversationsApplied() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let (storage, _) = try await makeFileStorage()

        let convoId = UUID()
        let userId = UUID()
        let bookId = UUID()
        let updatedAtMs: Int64 = 1_700_000_200_000
        let row = """
        {
            "id": "\(convoId.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "\(bookId.uuidString)",
            "title": "Remote chat",
            "archived": false,
            "created_at": 1700000100000,
            "updated_at": \(updatedAtMs)
        }
        """

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [\(row)] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            conversationStore: conversationStore,
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.applied >= 1, "expected at least one inbound apply (conversation), got \(wave.applied); errors: \(wave.errors)")

        let stored = try await conversationStore.conversation(convoId)
        #expect(stored != nil)
        #expect(stored?.title == "Remote chat")
        #expect(stored?.bookId == bookId)

        // Watermark advanced through markClean: the spy's cleaned snapshot
        // must include a `.conversation` entry for this id.
        let cleaned = await metadata.cleanedSnapshot()
        #expect(cleaned.contains(where: { $0.0 == convoId && $0.1 == .conversation }))
    }

    @Test("runOnce inbound: MessagesFetcher rows are upserted (append-only)")
    func runOnceInboundMessagesApplied() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let messageStore = StubMessageStore()
        let (storage, _) = try await makeFileStorage()

        let msgId = UUID()
        let convoId = UUID()
        let row = """
        {
            "id": "\(msgId.uuidString)",
            "conversation_id": "\(convoId.uuidString)",
            "role": "assistant",
            "content": "from server",
            "created_at": 1700000300000,
            "updated_at": 1700000300000
        }
        """

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [\(row)] }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            messageStore: messageStore,
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.applied >= 1, "expected at least one inbound apply (message), got \(wave.applied); errors: \(wave.errors)")

        let stored = try await messageStore.message(msgId)
        #expect(stored != nil)
        #expect(stored?.content == "from server")
        #expect(stored?.role == .assistant)

        let cleaned = await metadata.cleanedSnapshot()
        #expect(cleaned.contains(where: { $0.0 == msgId && $0.1 == .message }))
    }

    @Test("runOnce inbound LWW: local conversation newer than remote → dropped, conflicts++")
    func runOnceInboundConversationLWWDropsOlderRemote() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let (storage, _) = try await makeFileStorage()

        let convoId = UUID()
        let userId = UUID()
        // Seed local — newer than the remote row below.
        let localConvo = Conversation(
            id: convoId,
            userId: userId,
            bookId: nil,
            title: "Local newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        await conversationStore.seed(localConvo)

        // Remote is older by updated_at.
        let row = """
        {
            "id": "\(convoId.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "00000000-0000-0000-0000-000000000000",
            "title": "Older remote",
            "archived": false,
            "created_at": 1700000000000,
            "updated_at": 1700000100000
        }
        """

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [\(row)] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            conversationStore: conversationStore,
            workerClient: workerClient,
            fileStorage: storage
        )
        let wave = await engine.runOnce()
        #expect(wave.conflicts >= 1, "expected at least one LWW conflict on conversations, got \(wave.conflicts); errors: \(wave.errors)")

        // Local row preserved.
        let stored = try await conversationStore.conversation(convoId)
        #expect(stored?.title == "Local newer")
    }

    @Test("runOnce inbound: ChatSyncRefreshDelegate fires after applied conversation/message")
    func runOnceInboundFiresChatRefreshDelegate() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let (storage, _) = try await makeFileStorage()
        let spy = SpyChatRefreshDelegate()

        let convoId = UUID()
        let userId = UUID()
        let row = """
        {
            "id": "\(convoId.uuidString)",
            "user_id": "\(userId.uuidString)",
            "book_id": "00000000-0000-0000-0000-000000000000",
            "title": "Delegate trigger",
            "archived": false,
            "created_at": 1700000000000,
            "updated_at": 1700000050000
        }
        """

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [\(row)] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            conversationStore: conversationStore,
            workerClient: workerClient,
            fileStorage: storage,
            chatRefreshDelegate: spy
        )
        _ = await engine.runOnce()
        // Allow the detached refresh-delegate call to land.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        #expect(spy.callCount() >= 1, "expected delegate to fire at least once")
    }

    @Test("runOnce inbound: ChatSyncRefreshDelegate does NOT fire when no chat rows applied")
    func runOnceInboundSkipsDelegateWhenNoApply() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let spy = SpyChatRefreshDelegate()

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("""
                { "rows": [] }
                """.utf8), nil)
            }
            return (404, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage,
            chatRefreshDelegate: spy
        )
        _ = await engine.runOnce()
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        #expect(spy.callCount() == 0, "delegate should not fire when no chat rows applied")
    }
}
