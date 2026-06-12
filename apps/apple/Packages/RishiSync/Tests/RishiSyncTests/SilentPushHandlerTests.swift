#if canImport(UIKit)
import Testing
import Foundation
import UIKit
@testable import RishiSync
import RishiAPI
import RishiCore
import RishiLibrary

/// SYNC-06 (iOS side) — `SilentPushHandler` parses the silent-push payload
/// envelope and routes a sync wake into `SyncEngine.runOnce`. End-to-end
/// emission from the worker is deferred to WORKER-TICKETS Ticket 3.
@Suite("SilentPushHandler — silent-push routing", .serialized)
struct SilentPushHandlerTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {}
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}
    }
    private actor StubBookStore: BookStore {
        func books(for userId: UserID) async throws -> [Book] { [] }
        func book(_ id: BookID) async throws -> Book? { nil }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}
    }
    private actor StubPositionStore: PositionStore {
        func position(for bookId: BookID) async throws -> Position? { nil }
        func upsert(_ position: Position) async throws {}
        func delete(_ id: PositionID) async throws {}
    }
    private actor StubHighlightStore: HighlightStore {
        func highlights(for bookId: BookID) async throws -> [Highlight] { [] }
        func highlight(_ id: HighlightID) async throws -> Highlight? { nil }
        func upsert(_ highlight: Highlight) async throws {}
        func delete(_ id: HighlightID) async throws {}
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

    // MARK: - URLProtocol counter

    final class SilentPushMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
        nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
        override class var storage: MockURLProtocolStorage { _storage }
        static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
            get { _storage.handler } set { _storage.handler = newValue }
        }
        static func reset() { _storage.reset() }
        static func capturedSnapshot() -> [URLRequest] { _storage.captured }
    }

    // MARK: - Helpers

    private func makeEngine(
        changesResponseBody: Data,
        captureChangesPath: Bool = true
    ) async throws -> SyncEngine {
        SilentPushMockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SilentPushMockURLProtocol.self]
        let session = URLSession(configuration: config)
        SilentPushMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, changesResponseBody, nil)
            }
            return (404, Data(), nil)
        }
        let client = WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
        let metadata = StubMetadata()
        let queue = SyncQueue(metadataStore: metadata)
        let bookStore = StubBookStore()
        let positionStore = StubPositionStore()
        let highlightStore = StubHighlightStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-push-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let bookUploader = BookUploader(workerClient: client, metadataStore: metadata, fileStorage: fileStorage)
        let positionUploader = PositionUploader(workerClient: client, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata)
        let highlightUploader = HighlightUploader(workerClient: client, highlightStore: highlightStore, metadataStore: metadata)
        let conversationUploader = ConversationUploader(workerClient: client, conversationStore: StubConversationStore(), metadataStore: metadata)
        let messageUploader = MessageUploader(workerClient: client, messageStore: StubMessageStore(), metadataStore: metadata)
        let fetcher = RemoteChangeFetcher(workerClient: client, metadataStore: metadata)
        let applier = ChangeApplier(bookStore: bookStore, positionStore: positionStore, highlightStore: highlightStore, metadataStore: metadata)
        return SyncEngine(
            queue: queue,
            metadataStore: metadata,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            fetcher: fetcher,
            applier: applier
        )
    }

    private func emptyChanges() -> Data {
        Data("""
        { "changes": [] }
        """.utf8)
    }

    private func nonEmptyChanges() throws -> Data {
        let position = Position(bookId: UUID(), locator: "pdf-v1:page:1", percentComplete: 0.5, updatedAt: Date())
        let payload = try SyncPayloadCodec.encodePosition(position)
        let change = SyncChange(
            kind: SyncEntityKind.position.rawValue,
            id: position.id,
            payload: payload,
            updatedAt: position.updatedAt,
            deleted: false
        )
        struct ResponseBody: Encodable { let changes: [SyncChange] }
        return try JSONEncoder().encode(ResponseBody(changes: [change]))
    }

    // MARK: - Tests

    @Test("Missing rishi.kind → completion(.noData), no captured worker calls")
    func missingKindReturnsNoData() async throws {
        let engine = try await makeEngine(changesResponseBody: emptyChanges())
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1]
            // Note: no "rishi" subdict — irrelevant payload.
        ]

        let result = await withCheckedContinuation { (cont: CheckedContinuation<UIBackgroundFetchResult, Never>) in
            SilentPushHandler.handle(userInfo, engine: engine) { outcome in
                cont.resume(returning: outcome)
            }
        }
        #expect(result == .noData)
        // Engine should not have been triggered — no /api/sync/changes call.
        let captured = SilentPushMockURLProtocol.capturedSnapshot()
        #expect(captured.isEmpty)
    }

    @Test("rishi.kind == sync.changed + remote fetches 1 change → completion(.newData)")
    func validPayloadWithChangesReturnsNewData() async throws {
        let engine = try await makeEngine(changesResponseBody: try nonEmptyChanges())
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "rishi": ["kind": "sync.changed"]
        ]
        let result = await withCheckedContinuation { (cont: CheckedContinuation<UIBackgroundFetchResult, Never>) in
            SilentPushHandler.handle(userInfo, engine: engine) { outcome in
                cont.resume(returning: outcome)
            }
        }
        #expect(result == .newData)
        // Engine SHOULD have hit /api/sync/changes.
        let captured = SilentPushMockURLProtocol.capturedSnapshot()
        let touchedChanges = captured.contains { $0.url?.path == "/api/sync/changes" }
        #expect(touchedChanges)
    }

    @Test("rishi.kind == sync.changed + remote fetches 0 changes → completion(.noData)")
    func validPayloadEmptyChangesReturnsNoData() async throws {
        let engine = try await makeEngine(changesResponseBody: emptyChanges())
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "rishi": ["kind": "sync.changed"]
        ]
        let result = await withCheckedContinuation { (cont: CheckedContinuation<UIBackgroundFetchResult, Never>) in
            SilentPushHandler.handle(userInfo, engine: engine) { outcome in
                cont.resume(returning: outcome)
            }
        }
        #expect(result == .noData)
    }
}

#endif
