import Testing
import Foundation
@testable import RishiSync
import RishiAPI
import RishiCore
import RishiLibrary

/// Plan 09-06 Task 1 — SyncEngine.markConversationDirty + markMessageDirty.
///
/// Mirrors the existing markBookDirty/markHighlightDirty pattern from
/// `SyncEngineTests`: a write to the metadata store, an enqueue into the
/// `SyncQueue`, a refresh of the pending count. The engine MUST log + swallow
/// store failures (never throw) so a bad UNIQUE collision can't crash the chat
/// turn.
@Suite("SyncEngine — chat dirty marks (Plan 09-06)", .serialized)
struct SyncEngineChatDirtyTests {

    // MARK: - Stubs (copied from SyncEngineTests — keeps each suite self-contained)

    private actor StubMetadata: SyncMetadataStore {
        var dirty: [SyncPendingItem] = []
        var cleaned: [(UUID, SyncEntityKind)] = []
        var globalCursor: Date?

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
    }

    private actor StubBookStore: BookStore {
        var rows: [BookID: Book] = [:]
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
    }

    private actor StubPositionStore: PositionStore {
        var rows: [BookID: Position] = [:]
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key { rows[key] = nil }
        }
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
        func conversations(for userId: UserID) async throws -> [Conversation] { [] }
        func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
        func upsert(_ conversation: Conversation) async throws {}
        func delete(_ id: ConversationID) async throws {}
    }

    private actor StubMessageStore: MessageStore {
        func messages(for conversationId: ConversationID) async throws -> [Message] { [] }
        func message(_ id: MessageID) async throws -> Message? { nil }
        func upsert(_ message: Message) async throws {}
        func delete(_ id: MessageID) async throws {}
    }

    // MARK: - Helpers

    private func makeEngine(metadata: any SyncMetadataStore) async throws -> (SyncEngine, SyncQueue) {
        let session = URLSession(configuration: .ephemeral)
        let workerClient = WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
        let bookStore = StubBookStore()
        let positionStore = StubPositionStore()
        let highlightStore = StubHighlightStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-sync-chatdirty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(rootURL: root, bookStore: StubBookStore(), coverExtractors: [:])
        let queue = SyncQueue(metadataStore: metadata)
        let bookUploader = BookUploader(workerClient: workerClient, metadataStore: metadata, fileStorage: storage, userIdProvider: { "test-user" })
        let positionUploader = PositionUploader(workerClient: workerClient, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata)
        let highlightUploader = HighlightUploader(workerClient: workerClient, highlightStore: highlightStore, metadataStore: metadata)
        let conversationStore = StubConversationStore()
        let messageStore = StubMessageStore()
        let conversationUploader = ConversationUploader(workerClient: workerClient, conversationStore: conversationStore, metadataStore: metadata)
        let messageUploader = MessageUploader(workerClient: workerClient, messageStore: messageStore, metadataStore: metadata)
        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        let applier = ChangeApplier(bookStore: bookStore, positionStore: positionStore, highlightStore: highlightStore, metadataStore: metadata)
        // Phase 16-05 — dedicated chat-sync fetchers.
        let conversationsFetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let messagesFetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        let engine = SyncEngine(
            config: .init(positionDebounceWindow: 0.1, batchLimit: 50, backgroundRefreshInterval: 3600),
            queue: queue,
            metadataStore: metadata,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            fetcher: fetcher,
            applier: applier,
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore
        )
        return (engine, queue)
    }

    // MARK: - Tests

    @Test("markConversationDirty → metadata row + queue item with kind=.conversation")
    func markConversationDirtyEnqueues() async throws {
        let metadata = StubMetadata()
        let (engine, queue) = try await makeEngine(metadata: metadata)

        let convoId: ConversationID = UUID()
        await engine.markConversationDirty(convoId)

        let dirty = await metadata.currentDirty()
        #expect(dirty.count == 1)
        #expect(dirty.first?.entityId == convoId)
        #expect(dirty.first?.kind == .conversation)

        let items = await queue._drainForTests()
        #expect(items.contains(SyncQueueItem(entityId: convoId, kind: .conversation)))
    }

    @Test("markMessageDirty → metadata row + queue item with kind=.message")
    func markMessageDirtyEnqueues() async throws {
        let metadata = StubMetadata()
        let (engine, queue) = try await makeEngine(metadata: metadata)

        let messageId: MessageID = UUID()
        await engine.markMessageDirty(messageId)

        let dirty = await metadata.currentDirty()
        #expect(dirty.count == 1)
        #expect(dirty.first?.entityId == messageId)
        #expect(dirty.first?.kind == .message)

        let items = await queue._drainForTests()
        #expect(items.contains(SyncQueueItem(entityId: messageId, kind: .message)))
    }

    @Test("markConversationDirty + markBookDirty coexist without colliding")
    func chatDirtyDoesNotInterfereWithBookDirty() async throws {
        let metadata = StubMetadata()
        let (engine, _) = try await makeEngine(metadata: metadata)

        let bookId = UUID()
        let convoId: ConversationID = UUID()
        await engine.markBookDirty(bookId)
        await engine.markConversationDirty(convoId)

        let dirty = await metadata.currentDirty()
        #expect(dirty.count == 2)
        #expect(dirty.contains(where: { $0.entityId == bookId && $0.kind == .book }))
        #expect(dirty.contains(where: { $0.entityId == convoId && $0.kind == .conversation }))
    }
}
