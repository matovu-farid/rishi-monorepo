import Testing
import Foundation
@testable import RishiSync
import RishiCore
import RishiCore

/// Plan 34-10 (SRP) — focused tests for the three collaborators extracted out
/// of `SyncEngine.runOnce`: `SyncStatusReporter`, `ChatInboundMerger`, and
/// (indirectly) the drain semantics. The existing `SyncEngineTests` /
/// `SyncEngineChatDirtyTests` continue to pin the integrated wave behavior;
/// these tests exercise the extracted seams directly.
@Suite("SyncEngine collaborators (Plan 34-10)", .serialized)
struct SyncEngineCollaboratorsTests {

    // MARK: - Shared stubs

    private actor StubMetadata: SyncMetadataStore {
        var dirty: [SyncPendingItem] = []
        var cleaned: [(UUID, SyncEntityKind)] = []
        var globalCursor: Date?

        func seedGlobalCursor(_ date: Date?) { globalCursor = date }
        func seedDirty(_ item: SyncPendingItem) { dirty.append(item) }

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
        func cleanedSnapshot() -> [(UUID, SyncEntityKind)] { cleaned }
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
        func messages(for conversationId: ConversationID) async throws -> [Message] {
            rows.values.filter { $0.conversationId == conversationId }
        }
        func message(_ id: MessageID) async throws -> Message? { rows[id] }
        func upsert(_ message: Message) async throws { rows[message.id] = message }
        func delete(_ id: MessageID) async throws { rows.removeValue(forKey: id) }
    }

    // Distinct URLProtocol storage so these tests don't race other suites.
    final class CollabMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
        nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
        override class var storage: MockURLProtocolStorage { _storage }
        static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
            get { _storage.handler } set { _storage.handler = newValue }
        }
        static func reset() { _storage.reset() }
    }

    private func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollabMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    // MARK: - SyncStatusReporter

    @Test("setRunning toggles isRunning and clears lastError on the running edge")
    func reporterSetRunningClearsErrorWhenRunning() async {
        let metadata = StubMetadata()
        let reporter = SyncStatusReporter(metadataStore: metadata)
        let status = SyncStatus(pendingCount: 7, isRunning: false, lastError: "boom")

        reporter.setRunning(true, on: status)
        let running = status.snapshot()
        #expect(running.isRunning == true)
        #expect(running.lastError == nil)        // cleared on the running edge
        #expect(running.pendingCount == 7)       // other fields preserved
    }

    @Test("setRunning(false) preserves the existing lastError")
    func reporterSetRunningKeepsErrorWhenStopping() async {
        let metadata = StubMetadata()
        let reporter = SyncStatusReporter(metadataStore: metadata)
        let status = SyncStatus(isRunning: true, lastError: "previous")

        reporter.setRunning(false, on: status)
        let stopped = status.snapshot()
        #expect(stopped.isRunning == false)
        #expect(stopped.lastError == "previous")
    }

    @Test("setRunning is a no-op when no status is bound")
    func reporterSetRunningNoStatusIsSafe() async {
        let reporter = SyncStatusReporter(metadataStore: StubMetadata())
        reporter.setRunning(true, on: nil)   // must not crash
    }

    @Test("refreshPendingCount re-reads the metadata store's pending count")
    func reporterRefreshPendingCount() async {
        let metadata = StubMetadata()
        await metadata.seedDirty(SyncPendingItem(entityId: UUID(), kind: .book))
        await metadata.seedDirty(SyncPendingItem(entityId: UUID(), kind: .position))
        let reporter = SyncStatusReporter(metadataStore: metadata)
        let status = SyncStatus(pendingCount: 0)

        await reporter.refreshPendingCount(on: status)
        #expect(status.snapshot().pendingCount == 2)
    }

    @Test("snapshotStatus publishes cursor + pending + first error, isRunning=false")
    func reporterSnapshotStatus() async {
        let metadata = StubMetadata()
        let cursor = Date(timeIntervalSince1970: 1_900_000_000)
        await metadata.seedGlobalCursor(cursor)
        await metadata.seedDirty(SyncPendingItem(entityId: UUID(), kind: .book))
        let reporter = SyncStatusReporter(metadataStore: metadata)
        let status = SyncStatus(isRunning: true)

        await reporter.snapshotStatus(error: "fetch: down", on: status)
        let snap = status.snapshot()
        #expect(snap.lastSyncedAt == cursor)
        #expect(snap.pendingCount == 1)
        #expect(snap.isRunning == false)
        #expect(snap.lastError == "fetch: down")
    }

    // MARK: - ChatInboundMerger

    @Test("merge upserts new conversations + messages and counts chatRowsApplied")
    func mergeAppliesInboundRows() async throws {
        CollabMockURLProtocol.reset()
        let workerClient = makeWorkerClient()
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let messageStore = StubMessageStore()

        let convoId = UUID()
        let msgId = UUID()
        let convoRow = """
        { "id": "\(convoId.uuidString)", "user_id": "\(UUID().uuidString)",
          "book_id": "\(UUID().uuidString)", "title": "Remote",
          "archived": false, "created_at": 1700000100000, "updated_at": 1700000200000 }
        """
        let msgRow = """
        { "id": "\(msgId.uuidString)", "conversation_id": "\(convoId.uuidString)",
          "role": "assistant", "content": "hi", "created_at": 1700000300000,
          "updated_at": 1700000300000 }
        """
        CollabMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/api/sync/conversations") {
                return (200, Data("{ \"rows\": [\(convoRow)] }".utf8), nil)
            }
            if url.contains("/api/sync/messages") {
                return (200, Data("{ \"rows\": [\(msgRow)] }".utf8), nil)
            }
            return (404, Data(), nil)
        }

        let merger = ChatInboundMerger(
            conversationsFetcher: ConversationsFetcher(workerClient: workerClient, metadataStore: metadata),
            messagesFetcher: MessagesFetcher(workerClient: workerClient, metadataStore: metadata),
            conversationStore: conversationStore,
            messageStore: messageStore,
            metadataStore: metadata
        )
        let result = await merger.merge()
        #expect(result.applied == 2, "errors: \(result.errors)")
        #expect(result.chatRowsApplied == 2)
        #expect(result.conflicts == 0)
        #expect(try await conversationStore.conversation(convoId) != nil)
        #expect(try await messageStore.message(msgId) != nil)
    }

    @Test("merge LWW: local conversation newer than remote → dropped, conflict counted")
    func mergeDropsOlderRemoteConversation() async throws {
        CollabMockURLProtocol.reset()
        let workerClient = makeWorkerClient()
        let metadata = StubMetadata()
        let conversationStore = StubConversationStore()
        let messageStore = StubMessageStore()

        let convoId = UUID()
        let userId = UUID()
        await conversationStore.seed(Conversation(
            id: convoId, userId: userId, bookId: nil, title: "Local newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        ))
        let olderRemote = """
        { "id": "\(convoId.uuidString)", "user_id": "\(userId.uuidString)",
          "book_id": "00000000-0000-0000-0000-000000000000", "title": "Older remote",
          "archived": false, "created_at": 1700000000000, "updated_at": 1700000100000 }
        """
        CollabMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/api/sync/conversations") {
                return (200, Data("{ \"rows\": [\(olderRemote)] }".utf8), nil)
            }
            if url.contains("/api/sync/messages") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            return (404, Data(), nil)
        }

        let merger = ChatInboundMerger(
            conversationsFetcher: ConversationsFetcher(workerClient: workerClient, metadataStore: metadata),
            messagesFetcher: MessagesFetcher(workerClient: workerClient, metadataStore: metadata),
            conversationStore: conversationStore,
            messageStore: messageStore,
            metadataStore: metadata
        )
        let result = await merger.merge()
        #expect(result.conflicts == 1, "errors: \(result.errors)")
        #expect(result.applied == 0)
        #expect(result.chatRowsApplied == 0)
        let stored = try await conversationStore.conversation(convoId)
        #expect(stored?.title == "Local newer")   // local preserved
    }
}
