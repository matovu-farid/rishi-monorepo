@testable import rishi
import Testing
import Foundation
import os
import SwiftData
import CryptoKit

@MainActor
private final class CredentialStagingDependencyBox {
    var value: AppDependencies?
    var admittedTransaction: AccountChangeTransaction?
    var rejectedCode: CredentialRejectionCode?
    var rejectedContext: CredentialRejectionContext?
}




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

    private struct DeniedConsent: WorkerDataUseConsentProvider {
        func hasCurrentDataUseConsent() async -> Bool { false }
    }

    private final class LockedRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private actor CompletionProbe {
        private var completed = false

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var dirty: [SyncPendingItem] = []
        var cleaned: [(UUID, SyncEntityKind)] = []
        var globalCursor: Date?
        var resetCalls = 0
        var markDirtyFailures = 0
        var cursors: [String: SyncCursorState] = [:]
        var cursorSaveCount = 0
        var recovery: SyncRecoveryState?
        var recoveryPreparationFailure: String?
        var recoveryEvents: [String] = []
        func failRecoveryPreparation(_ stage: String) { recoveryPreparationFailure = stage }
        func recoveryEventSnapshot() -> [String] { recoveryEvents }
        var positionOperations: [UUID: UUID] = [:]
        var positionDirtyTimes: [UUID: Date] = [:]
        func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? { positionOperations[entityId] }
        func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
            if let operation = positionOperations[entityId] { return operation }
            let operation = UUID(); positionOperations[entityId] = operation; return operation
        }
        func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
            kind == .position ? positionDirtyTimes[entityId] : nil
        }


        private struct InjectedFailure: Error {}

        func seedGlobalCursor(_ date: Date?) { globalCursor = date }
        func seedRecovery(_ state: SyncRecoveryState?) { recovery = state }
        func failNextMarkDirty() { markDirtyFailures += 1 }

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
            if markDirtyFailures > 0 {
                markDirtyFailures -= 1
                throw InjectedFailure()
            }
            if kind == .position { positionOperations[entityId] = UUID(); positionDirtyTimes[entityId] = Date() }
            if !dirty.contains(where: { $0.entityId == entityId && $0.kind == kind }) {
                dirty.append(SyncPendingItem(entityId: entityId, kind: kind))
            }
        }
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            dirty.removeAll { $0.entityId == entityId && $0.kind == kind }
            positionDirtyTimes[entityId] = nil; positionOperations[entityId] = nil
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

        func resetAll() async throws {
            dirty.removeAll()
            cleaned.removeAll()
            globalCursor = nil
            resetCalls += 1
            cursors.removeAll()
            recovery = nil
        }

        func cursorState(for scope: SyncCursorScope) async throws -> SyncCursorState? {
            cursors[scope.rawValue]
        }
        func saveCursorState(_ state: SyncCursorState) async throws {
            cursors[state.scope.rawValue] = state
            cursorSaveCount += 1
        }
        func clearCursorState(for scope: SyncCursorScope) async throws {
            if scope == .recovery {
                recoveryEvents.append("cursor-clear")
                if recovery?.reason == .rejectedPosition, recoveryPreparationFailure == "cursor" { throw InjectedFailure() }
            }
            cursors[scope.rawValue] = nil
        }
        func recoveryState() async throws -> SyncRecoveryState? { recovery }
        func saveRecoveryState(_ state: SyncRecoveryState) async throws {
            recoveryEvents.append("marker")
            if state.reason == .rejectedPosition, recoveryPreparationFailure == "marker" { throw InjectedFailure() }
            recovery = state
        }
        func retireRejectedPosition(entityId: UUID, expectedDirtyAt: Date?, expectedOperationId: UUID, previousLastSyncedAt: Date?) async throws -> Bool {
            recoveryEvents.append("retire")
            guard positionOperations[entityId] == expectedOperationId, positionDirtyTimes[entityId] == expectedDirtyAt else { return false }
            dirty.removeAll { $0.entityId == entityId && $0.kind == .position }
            positionDirtyTimes[entityId] = nil; positionOperations[entityId] = nil
            return true
        }
        func clearRecoveryState() async throws { recovery = nil }

        func currentDirty() -> [SyncPendingItem] { dirty }
        func cleanedSnapshot() -> [(UUID, SyncEntityKind)] { cleaned }
        func resetCallCount() -> Int { resetCalls }
        func incrementalCursor() -> SyncCursorState? { cursors[SyncCursorScope.incremental.rawValue] }
        func savedCursorCount() -> Int { cursorSaveCount }
        func recoverySnapshot() -> SyncRecoveryState? { recovery }
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
        var upsertPause: CommitPause?
        func pauseNextUpsert(_ pause: CommitPause) { upsertPause = pause }
        func seed(_ position: Position) { rows[position.bookId] = position }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws {
            if let pause = upsertPause { upsertPause = nil; await pause.enter() }
            rows[position.bookId] = position
        }
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

    private actor StubChapterIndexPersistence: ChapterIndexPersistence {
        func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? { nil }
        func upsertChapterIndex(_ index: ChapterIndex) async throws {}
        func markChapterIndexDirty(bookID: BookID) async throws {}
    }

    private actor StubConversationStore: ConversationStore {
        var rows: [ConversationID: Conversation] = [:]
        var upsertPause: CommitPause?
        func pauseNextUpsert(_ pause: CommitPause) { upsertPause = pause }
        func seed(_ convo: Conversation) { rows[convo.id] = convo }
        func conversations(for userId: UserID) async throws -> [Conversation] {
            rows.values.filter { $0.userId == userId }
        }
        func conversation(_ id: ConversationID) async throws -> Conversation? { rows[id] }
        func upsert(_ conversation: Conversation) async throws {
            if let pause = upsertPause { upsertPause = nil; await pause.enter() }
            rows[conversation.id] = conversation
        }
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
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
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
        chatRefreshDelegate: (any ChatSyncRefreshDelegate)? = nil,
        dataUseConsentProvider: any WorkerDataUseConsentProvider = AlwaysAllowWorkerDataUseConsentProvider(),
        ownerID: UUID = UUID(),
        bookReadinessPolicy: BookReadinessPolicy? = nil,
        bookUploaderOverride: BookUploader? = nil
    ) -> SyncEngine {
        let testUserId = ownerID
        let currentUserId: @Sendable () async -> UserID? = { testUserId }
        let queue = SyncQueue(metadataStore: metadata)
        let bookUploader = bookUploaderOverride ?? BookUploader(workerClient: workerClient, metadataStore: metadata, fileStorage: fileStorage, userIdProvider: { "test-user" })
        let positionUploader = PositionUploader(workerClient: workerClient, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata, currentUserId: currentUserId)
        let highlightUploader = HighlightUploader(workerClient: workerClient, highlightStore: highlightStore, metadataStore: metadata)
        let conversationUploader = ConversationUploader(workerClient: workerClient, conversationStore: conversationStore, metadataStore: metadata)
        let messageUploader = MessageUploader(workerClient: workerClient, messageStore: messageStore, metadataStore: metadata)
        let bookmarkUploader = BookmarkUploader(workerClient: workerClient, bookmarkStore: EngineStubBookmarkStore(), metadataStore: metadata)
        let chapterIndexUploader = ChapterIndexUploader(
            workerClient: workerClient,
            bookStore: bookStore,
            persistence: StubChapterIndexPersistence(),
            metadataStore: metadata
        )
        let fetcher = RemoteChangeFetcher(workerClient: workerClient, metadataStore: metadata)
        let conversationsFetcher = ConversationsFetcher(workerClient: workerClient, metadataStore: metadata)
        let messagesFetcher = MessagesFetcher(workerClient: workerClient, metadataStore: metadata)
        let applier = ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: EngineStubBookmarkStore(),
            metadataStore: metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                integration.userIdProvider = currentUserId

                return integration
            }()
        )
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
            chapterIndexUploader: chapterIndexUploader,
            fetcher: fetcher,
            applier: applier,
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            dataUseConsentProvider: dataUseConsentProvider,
            currentUserId: currentUserId,
            bookReadinessPolicy: bookReadinessPolicy
            ),
            chatRefreshDelegate: chatRefreshDelegate
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

    private func waitForRequest(path: String) async throws {
        for _ in 0..<100 {
            if EngineMockURLProtocol.capturedSnapshot().contains(where: { $0.url?.path == path }) {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestTimeout.request(path)
    }

    private enum TestTimeout: Error {
        case request(String)
    }

    // MARK: - Tests

    @Test("consent blocked runOnce reports the requirement without making a network request")
    func runOnceBlockedByConsentReportsStatusWithoutNetwork() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        EngineMockURLProtocol.handler = { _ in
            (500, Data(), nil)
        }

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage,
            dataUseConsentProvider: DeniedConsent()
        )
        let status = SyncStatus()
        await engine.bind(status: status)

        let wave = await engine.runOnce()

        #expect(wave == SyncEngine.Wave())
        #expect(EngineMockURLProtocol.capturedSnapshot().isEmpty)
        #expect(status.snapshot().isRunning == false)
        #expect(status.snapshot().lastError == "Sync requires data-use consent")
    }

    @Test("concurrent runOnce calls share one active wave")
    func concurrentRunOnceCallsShareOneActiveWave() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let fetchGate = DispatchSemaphore(value: 0)
        let changesRequestCounter = LockedRequestCounter()
        defer {
            fetchGate.signal()
            fetchGate.signal()
        }

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if changesRequestCounter.increment() == 1 { fetchGate.wait() }
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        let first = Task { await engine.runOnce() }
        try await waitForRequest(path: "/api/sync/changes")
        let second = Task { await engine.runOnce() }

        try await Task.sleep(for: .milliseconds(50))
        let activeWaveRequests = EngineMockURLProtocol
            .capturedSnapshot()
            .filter { $0.url?.path == "/api/sync/changes" }
        #expect(activeWaveRequests.count == 1)

        fetchGate.signal()
        _ = await first.value
        _ = await second.value
    }

    @Test("a canceled waiter cannot cancel a wave while a joining callback is on MainActor")
    func canceledWaiterPreservesJoiningWaveOwnershipDuringCallbackHop() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let fetchGate = DispatchSemaphore(value: 0)
        let changesRequestCounter = LockedRequestCounter()
        defer { fetchGate.signal() }

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if changesRequestCounter.increment() == 1 {
                    fetchGate.wait()
                }
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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
        let callbackEntered = CompletionProbe()

        let first = Task { await engine.runOnce() }
        try await waitForRequest(path: "/api/sync/changes")
        let joining = Task {
            await engine.runOnce(onWaveID: { _ in
                await callbackEntered.markCompleted()
                try? await Task.sleep(for: .milliseconds(150))
            })
        }

        for _ in 0..<100 {
            if await callbackEntered.isCompleted() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await callbackEntered.isCompleted())

        first.cancel()
        _ = await first.value
        fetchGate.signal()
        _ = await joining.value

        let conversationFetches = EngineMockURLProtocol.capturedSnapshot()
            .filter { $0.url?.path == "/api/sync/conversations" && $0.httpMethod == "GET" }
        #expect(conversationFetches.count == 1)
    }

    @Test("requestSync schedules a follow-up without overlapping the active wave")
    func requestSyncSchedulesFollowUpWithoutOverlap() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let fetchGate = DispatchSemaphore(value: 0)
        let changesRequestCounter = LockedRequestCounter()
        defer { fetchGate.signal(); fetchGate.signal() }

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if changesRequestCounter.increment() == 1 { fetchGate.wait() }
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        let first = Task { await engine.runOnce() }
        try await waitForRequest(path: "/api/sync/changes")
        await engine.requestSync()

        let beforeRelease = EngineMockURLProtocol
            .capturedSnapshot()
            .filter { $0.url?.path == "/api/sync/changes" }
        #expect(beforeRelease.count == 1)

        fetchGate.signal()
        _ = await first.value

        for _ in 0..<100 {
            let count = EngineMockURLProtocol
                .capturedSnapshot()
                .filter { $0.url?.path == "/api/sync/changes" }
                .count
            if count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let afterRelease = EngineMockURLProtocol
            .capturedSnapshot()
            .filter { $0.url?.path == "/api/sync/changes" }
        #expect(afterRelease.count == 2)
        fetchGate.signal()
        await engine.resetForAccountSwitch() // Drain this test's scheduled owner before resetting its URLProtocol fixture.
    }

    @Test("account reset cancels queued import sync work")
    func accountResetCancelsQueuedSyncWork() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let fetchGate = DispatchSemaphore(value: 0)
        let changesRequestCounter = LockedRequestCounter()
        defer { fetchGate.signal(); fetchGate.signal() }

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if changesRequestCounter.increment() == 1 { fetchGate.wait() }
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        let first = Task { await engine.runOnce() }
        try await waitForRequest(path: "/api/sync/changes")
        await engine.requestSync()
        let reset = Task { await engine.resetForAccountSwitch() }

        try await Task.sleep(for: .milliseconds(25))
        fetchGate.signal()
        await reset.value
        _ = await first.value

        let changeRequests = EngineMockURLProtocol
            .capturedSnapshot()
            .filter { $0.url?.path == "/api/sync/changes" }
        #expect(changeRequests.count == 1)
    }

    @Test("markBookDirty retries one transient metadata failure")
    func markBookDirtyRetriesTransientFailure() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let bookId = UUID()
        await metadata.failNextMarkDirty()

        let engine = makeEngine(
            metadata: metadata,
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            workerClient: workerClient,
            fileStorage: storage
        )

        let marked = await engine.markBookDirty(bookId)

        #expect(marked)
        #expect(await metadata.currentDirty().contains {
            $0.entityId == bookId && $0.kind == .book
        })
    }

    @Test("markBookDeleted requests a sync wave after queueing the tombstone")
    func markBookDeletedRequestsSync() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        let bookId = UUID()
        try await engine.markBookDeleted(bookId)

        try await waitForRequest(path: "/api/sync/changes")
        #expect(EngineMockURLProtocol.capturedSnapshot().contains {
            $0.url?.path == "/api/sync/changes"
        })
    }

    @MainActor
    @Test("credential cleanup reservation spans the real engine reset and an entered wave join", .timeLimit(.minutes(1)))
    func credentialCleanupReservesOwnerThroughResetWaveJoin() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let metadata = StubMetadata()
        let positions = StubPositionStore()
        let (storage, _) = try await makeFileStorage()
        let pause = CommitPause()
        await positions.pauseNextUpsert(pause)
        let remote = Position(bookId: UUID(), locator: "fixture", percentComplete: 0.3, updatedAt: Date())
        let change = SyncChange(kind: "position", id: remote.id,
                                payload: try SyncPayloadCodec.encodePosition(remote), updatedAt: remote.updatedAt, deleted: false)
        struct Response: Encodable { let changes: [SyncChange] }
        let body = try JSONEncoder().encode(Response(changes: [change]))
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" { return (200, body, nil) }
            return (200, Data("{\"rows\":[],\"events\":[]}".utf8), nil)
        }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
                                highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: session), fileStorage: storage)
        let wave = Task { await engine.runOnce() }
        await pause.waitUntilEntered()
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let cleanupEntered = CredentialStagingGate()
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(DerivedUserID.from("A")),
                                  accountGeneration: 2, persistAccountGeneration: { _ in }, credentialCleanup: { _ in
            await cleanupEntered.markEntered()
            await engine.resetForAccountSwitch()
        })
        let tx = try deps.beginAccountChange(expectedCredentialTicket: a.ticket)
        let completion = try #require(deps.retireCredentialAccount(tx))
        await cleanupEntered.waitUntilEntered()
        let ticket = authority.attemptTicket()
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try deps.beginAccountChange(expectedCredentialTicket: ticket)
        }
        #expect(authority.attemptTicket() == ticket)
        #expect(await metadata.resetCallCount() == 0)
        await pause.resume()
        _ = await wave.value
        await completion.value
        #expect(await metadata.resetCallCount() == 1)
        #expect(deps.cachedUserId == nil)
        _ = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
    }

    @MainActor
    @Test("definitively rejected initiating request unwinds before owned reset joins its real wave", .timeLimit(.minutes(1)))
    func definitiveRequestUnwindsBeforeOwnedReset() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let box = CredentialStagingDependencyBox()
        let worker = WorkerClient(baseURL: URL(string: "https://sync-credential-fixture.test")!, session: session,
                                  credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                                  admitCredentialRejection: { code, context in
            await MainActor.run {
                let result = box.value?.admitCredentialRejection(code, context: context) ?? .stale
                box.admittedTransaction = box.value?.pendingAccountChange
                box.rejectedCode = code
                box.rejectedContext = context
                return result
            }
        })
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                return (401, Data("{\"error\":{\"code\":\"INVALID_REFRESH_TOKEN\",\"message\":\"fixture\"}}".utf8), nil)
            }
            return (401, Data(), nil)
        }
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: StubPositionStore(),
                                highlightStore: StubHighlightStore(), workerClient: worker, fileStorage: storage)
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(DerivedUserID.from("A")),
                                  accountGeneration: 3, persistAccountGeneration: { _ in }, credentialCleanup: { _ in
            await engine.resetForAccountSwitch()
        })
        box.value = deps
        _ = await engine.runOnce()
        let tx = try #require(box.admittedTransaction)
        let completion = try #require(deps.retireCredentialAccount(tx))
        await completion.value
        #expect(await metadata.resetCallCount() == 1)
        #expect(deps.cachedUserId == nil)
        let refreshes = EngineMockURLProtocol.capturedSnapshot().filter { $0.url?.path == "/auth/refresh" }
        #expect(refreshes.count == 1)
        let refresh = try #require(refreshes.first)
        #expect(refresh.httpMethod == "POST")
        #expect(box.rejectedCode == .invalidRefreshToken)
        #expect(box.rejectedContext == a.rejectionContext)
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
    }

    @Test("account reset waits for an entered primary inbound apply before clearing account state")
    func resetForAccountSwitchWaitsForActiveWave() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let (storage, _) = try await makeFileStorage()
        let pause = CommitPause()
        await positionStore.pauseNextUpsert(pause)

        let pendingBookId = UUID()
        let pendingPosition = Position(bookId: pendingBookId, locator: "page:1", percentComplete: 0.2, updatedAt: Date())
        await positionStore.seed(pendingPosition)
        try await metadata.markDirty(entityId: pendingBookId, kind: .position)
        let remote = Position(bookId: UUID(), locator: "page:2", percentComplete: 0.4, updatedAt: Date())
        let change = SyncChange(kind: "position", id: remote.id,
            payload: try SyncPayloadCodec.encodePosition(remote), updatedAt: remote.updatedAt, deleted: false)
        struct Response: Encodable { let changes: [SyncChange] }
        let body = try JSONEncoder().encode(Response(changes: [change]))
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" { return (200, body, nil) }
            if request.httpMethod == "GET",
               ["/api/sync/conversations", "/api/sync/messages"].contains(request.url?.path ?? "") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            return (404, Data(), nil)
        }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positionStore,
            highlightStore: StubHighlightStore(), workerClient: workerClient, fileStorage: storage)
        let waveTask = Task { await engine.runOnce() }
        await pause.waitUntilEntered()
        let resetProbe = CompletionProbe()
        let resetTask = Task {
            await engine.resetForAccountSwitch()
            await resetProbe.markCompleted()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await resetProbe.isCompleted() == false)
        await pause.resume()
        _ = await waveTask.value
        await resetTask.value
        #expect(await resetProbe.isCompleted())
        #expect(await metadata.resetCallCount() == 1)
        #expect(await metadata.currentDirty().isEmpty)
        #expect(EngineMockURLProtocol.capturedSnapshot().allSatisfy { $0.url?.path != "/api/sync/push" })
    }

    @Test("account reset waits for an entered chat merge before clearing account state")
    func resetForAccountSwitchWaitsForActiveChatWave() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let conversations = StubConversationStore()
        let pause = CommitPause()
        await conversations.pauseNextUpsert(pause)
        let (storage, _) = try await makeFileStorage()
        let body = Data("""
        { "rows": [{ "id": "\(UUID().uuidString)", "user_id": "\(UUID().uuidString)",
          "book_id": "00000000-0000-0000-0000-000000000000", "title": "Remote chat", "archived": false,
          "created_at": 1700000100000, "updated_at": 1700000200000 }] }
        """.utf8)
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" { return (200, self.emptyChangesBody(), nil) }
            if request.url?.path == "/api/sync/conversations", request.httpMethod == "GET" { return (200, body, nil) }
            if request.url?.path == "/api/sync/messages", request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            return (404, Data(), nil)
        }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(), conversationStore: conversations,
            workerClient: workerClient, fileStorage: storage)
        let waveTask = Task { await engine.runOnce() }
        await pause.waitUntilEntered()
        let resetProbe = CompletionProbe()
        let resetTask = Task {
            await engine.resetForAccountSwitch()
            await resetProbe.markCompleted()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await resetProbe.isCompleted() == false)
        await pause.resume()
        _ = await waveTask.value
        await resetTask.value
        #expect(await resetProbe.isCompleted())
        #expect(await metadata.resetCallCount() == 1)
    }

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

    @Test("cursor pages are applied and committed only after each successful page")
    func runOnceConsumesCursorPages() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let firstBody = Data("""
        { "changes": [], "next_cursor": "page-2", "has_more": true, "cursor_scope": "incremental", "projection_complete": true }
        """.utf8)
        let secondBody = Data("""
        { "changes": [], "has_more": false, "cursor_scope": "incremental", "projection_complete": true }
        """.utf8)

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if request.url?.query?.contains("cursor=page-2") == true {
                    return (200, secondBody, nil)
                }
                return (200, firstBody, nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        #expect(wave.errors.isEmpty)
        let requests = EngineMockURLProtocol.capturedSnapshot().filter { $0.url?.path == "/api/sync/changes" }
        #expect(requests.count == 3) // Two apply pages, then one advisory verification readback.
        #expect(requests.map { $0.url?.query } == [nil, "cursor=page-2", nil])
        #expect(await metadata.incrementalCursor() == nil)
        #expect(await metadata.savedCursorCount() == 1)
    }

    @Test("recovery resumes from its cursor and promotes only after a complete terminal page")
    func runOnceResumesRecoveryBeforePromotion() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        await metadata.seedRecovery(SyncRecoveryState(reason: .incompleteProjection, accountGeneration: 0))
        try await metadata.saveCursorState(.init(
            scope: .recovery,
            cursor: "recovery-page-2",
            accountGeneration: 0
        ))
        let (storage, _) = try await makeFileStorage()
        let terminalBody = Data("""
        { "changes": [], "has_more": false, "cursor_scope": "full", "projection_complete": true }
        """.utf8)

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                if request.url?.query == "cursor=recovery-page-2" {
                    // A saved opaque cursor carries its scope; the endpoint omits the scope query.
                    return (200, terminalBody, nil)
                }
                #expect(request.url?.query == nil) // Advisory incremental readback after promotion.
                return (200, self.emptyChangesBody(), nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        #expect(wave.errors.isEmpty)
        #expect(EngineMockURLProtocol.capturedSnapshot().filter { $0.url?.path == "/api/sync/changes" }.map { $0.url?.query }
            == ["cursor=recovery-page-2", nil])
        #expect(await metadata.recoverySnapshot() == nil)
        let recoveryCursorState = try await metadata.cursorState(for: .recovery)
        #expect(recoveryCursorState == nil)
        #expect(await metadata.incrementalCursor() == nil)
    }

    @Test("incomplete terminal projection schedules durable recovery")
    func runOnceSchedulesRecoveryForIncompleteProjection() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let incompleteBody = Data("""
        { "changes": [], "has_more": false, "cursor_scope": "incremental", "projection_complete": false, "is_truncated": true }
        """.utf8)

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, incompleteBody, nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        _ = await engine.runOnce()

        #expect(await metadata.recoverySnapshot() == .init(
            reason: .incompleteProjection,
            accountGeneration: 0
        ))
    }

    @Test("an apply error leaves the page cursor uncommitted")
    func runOnceDoesNotCommitFailedPage() async throws {
        EngineMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let (storage, _) = try await makeFileStorage()
        let body = Data("""
        { "changes": [{ "kind": "unknown", "id": "11111111-1111-4111-8111-111111111111", "payload": {}, "updated_at": 807667200, "deleted": false }], "next_cursor": "must-not-save", "has_more": true, "cursor_scope": "incremental", "projection_complete": true }
        """.utf8)

        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/changes" {
                return (200, body, nil)
            }
            if request.url?.path == "/api/sync/conversations" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
            }
            if request.url?.path == "/api/sync/messages" && request.httpMethod == "GET" {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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

        #expect(wave.errors.contains { $0.contains("unknown kind") })
        #expect(await metadata.incrementalCursor() == nil)
        #expect(await metadata.savedCursorCount() == 0)
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
            if request.httpMethod == "GET",
               ["/api/sync/conversations", "/api/sync/messages"].contains(request.url?.path ?? "") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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
            if request.httpMethod == "GET",
               ["/api/sync/conversations", "/api/sync/messages"].contains(request.url?.path ?? "") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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
            if request.httpMethod == "GET",
               ["/api/sync/conversations", "/api/sync/messages"].contains(request.url?.path ?? "") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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
            if request.httpMethod == "GET",
               ["/api/sync/conversations", "/api/sync/messages"].contains(request.url?.path ?? "") {
                return (200, Data("{ \"rows\": [] }".utf8), nil)
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
    @Test("Durable reader publication bypasses debounce and releases finite admission")
    func readerCommitImmediate() async throws {
        let metadata = StubMetadata(); let positions = StubPositionStore(); let owner = UUID()
        let position = Position(bookId: UUID(), locator: "saved", updatedAt: Date(timeIntervalSince1970: 123))
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 17, bookID: position.bookId, contentRevision: UUID())
        let released = CompletionProbe()
        let authority = ReaderPositionPublicationAuthority(permit: permit, source: BookSourceAccessPermit()) {
            SourceEffectAdmission { Task { await released.markCompleted() } }
        }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        let result = try await engine.commitReaderPosition(position, authority: authority) { try await positions.upsert(position) }
        #expect(result == .committed)
        #expect(await metadata.currentDirty().contains(.init(entityId: position.bookId, kind: .position)))
        #expect(!(await metadata.hasProtectedPositionPublication(position.bookId)))
        #expect(try await positions.position(for: position.bookId) == position)
        // Release completion is scheduled synchronously by admission.release.
        while !(await released.isCompleted()) { await Task.yield() }
    }

    @Test("Failed upsert never dirties; failed publication protects exact saved snapshot for same-wave retry")
    func readerPublicationHandoff() async throws {
        EngineMockURLProtocol.reset()
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" { return (200, Data("{\"accepted_at\":123}".utf8), nil) }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" {
                return (200, Data("{\"rows\":[]}".utf8), nil)
            }
            return (200, Data("{\"changes\":[],\"complete\":true}".utf8), nil)
        }
        let metadata = StubMetadata(); let positions = StubPositionStore(); let owner = UUID()
        let position = Position(bookId: UUID(), locator: "durable", updatedAt: Date(timeIntervalSince1970: 123))
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 17, bookID: position.bookId, contentRevision: UUID())
        let authority = ReaderPositionPublicationAuthority(permit: permit, source: BookSourceAccessPermit()) { SourceEffectAdmission {} }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        await #expect(throws: (any Error).self) {
            try await engine.commitReaderPosition(position, authority: authority) { throw URLError(.cannotWriteToFile) }
        }
        #expect(await metadata.currentDirty().isEmpty)
        await metadata.failNextMarkDirty()
        #expect(try await engine.commitReaderPosition(position, authority: authority) { try await positions.upsert(position) } == .publicationDeferred)
        #expect(await metadata.hasProtectedPositionPublication(position.bookId))
        let wave = await engine.runOnce()
        #expect(wave.errors.isEmpty)
        #expect(wave.positionsPushed == 1)
        #expect(await metadata.currentDirty().isEmpty)
        #expect(!(await metadata.hasProtectedPositionPublication(position.bookId)))
        #expect(try await positions.position(for: position.bookId) == position)
    }

    @Test("Rejected position prepares fresh recovery before retirement and replays equal-time winner in same wave")
    func rejectedPositionSameWaveRecovery() async throws {
        EngineMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let local = Position(bookId: UUID(), locator: "rejected", updatedAt: Date(timeIntervalSince1970: 123))
        let remote = Position(bookId: local.bookId, locator: "winner", updatedAt: local.updatedAt)
        await positions.seed(local)
        try await metadata.markDirty(entityId: local.bookId, kind: .position)
        let change = SyncChange(kind: "position", id: remote.id, payload: try SyncPayloadCodec.encodePosition(remote), updatedAt: remote.updatedAt, deleted: false)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(change)
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" { return (200, Data("{\"accepted_at\":123,\"accepted\":false}".utf8), nil) }
            if request.url?.query?.contains("scope=full") == true {
                return (200, Data("{\"changes\":[\(encodedString)],\"projection_complete\":true}".utf8), nil)
            }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" { return (200, Data("{\"rows\":[]}".utf8), nil) }
            return (200, Data("{\"changes\":[]}".utf8), nil)
        }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage)
        let wave = await engine.runOnce()
        #expect(wave.positionsPushed == 0)
        #expect(wave.errors.isEmpty)
        let stored = try #require(try await positions.position(for: local.bookId))
        #expect(stored.id == local.id)
        #expect(stored.locator == remote.locator)
        #expect(await metadata.recoverySnapshot() == nil)
        let events = await metadata.recoveryEventSnapshot()
        #expect(events.prefix(3) == ["marker", "cursor-clear", "retire"])
    }

    @Test("Rejected preparation failure keeps mutation pending", arguments: ["marker", "cursor"])
    func rejectedPreparationFailure(_ stage: String) async throws {
        EngineMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let local = Position(bookId: UUID(), locator: "pending")
        await positions.seed(local); try await metadata.markDirty(entityId: local.bookId, kind: .position)
        await metadata.failRecoveryPreparation(stage)
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" { return (200, Data("{\"accepted_at\":123,\"accepted\":false}".utf8), nil) }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" { return (200, Data("{\"rows\":[]}".utf8), nil) }
            return (200, Data("{\"changes\":[]}".utf8), nil)
        }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage)
        let wave = await engine.runOnce()
        #expect(wave.errors.contains { $0.hasPrefix("position.recovery:") })
        #expect(await metadata.currentDirty().contains(.init(entityId: local.bookId, kind: .position)))
        #expect(!(await metadata.recoveryEventSnapshot().contains("retire")))
    }

    private actor CommitPause {
        var entered = false
        var entrants: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?
        func enter() async {
            entered = true
            entrants.forEach { $0.resume() }; entrants.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entrants.append($0) }
        }
        func resume() { release?.resume(); release = nil }
    }

    @Test("Local upsert and publication share the inbound and outbound book gate")
    func readerUpsertPublicationGate() async throws {
        EngineMockURLProtocol.reset()
        let networkResume = DispatchSemaphore(value: 0)
        defer { networkResume.signal() }
        EngineMockURLProtocol.handler = { _ in
            networkResume.wait()
            return (200, Data("{\"accepted_at\":123}".utf8), nil)
        }
        let metadata = StubMetadata(); let positions = StubPositionStore(); let owner = UUID()
        let local = Position(bookId: UUID(), locator: "durable", updatedAt: Date(timeIntervalSince1970: 123))
        let remote = Position(bookId: local.bookId, locator: "remote", updatedAt: local.updatedAt.addingTimeInterval(1))
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 5, bookID: local.bookId, contentRevision: UUID())
        let authority = ReaderPositionPublicationAuthority(permit: permit, source: BookSourceAccessPermit()) { SourceEffectAdmission {} }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = makeWorkerClient(session: makeSession())
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: worker, fileStorage: storage, ownerID: owner)
        let pause = CommitPause()
        let commit = Task {
            try await engine.commitReaderPosition(local, authority: authority) {
                try await positions.upsert(local)
                await pause.enter()
            }
        }
        await pause.waitUntilEntered()
        let applier = ChangeApplier(
            bookStore: StubBookStore(),
            positionStore: positions,
            highlightStore: StubHighlightStore(),
            bookmarkStore: EngineStubBookmarkStore(),
            metadataStore: metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                return integration
            }()
        )
        let change = SyncChange(kind: "position", id: remote.id, payload: try SyncPayloadCodec.encodePosition(remote), updatedAt: remote.updatedAt, deleted: false)
        let inboundStarted = CompletionProbe(); let outboundStarted = CompletionProbe()
        let inbound = Task { await inboundStarted.markCompleted(); return await applier.apply([change]) }
        let uploader = PositionUploader(workerClient: worker, positionStore: positions, bookStore: StubBookStore(), metadataStore: metadata)
        let outbound = Task {
            await outboundStarted.markCompleted()
            return try await uploader.pushPending(items: [.init(entityId: local.bookId, kind: .position)])
        }
        while !(await inboundStarted.isCompleted()) { await Task.yield() }
        while !(await outboundStarted.isCompleted()) { await Task.yield() }
        #expect(try await positions.position(for: local.bookId) == local)
        #expect(EngineMockURLProtocol.capturedSnapshot().isEmpty)
        await pause.resume()
        #expect(try await commit.value == .committed)
        #expect(await inbound.value.conflicts == 1)
        networkResume.signal()
        #expect(try await outbound.value == 1)
        #expect(try await positions.position(for: local.bookId) == local)
    }

    @Test("New durable movement supersedes older deferred publication without restoring its payload")
    func deferredMovementSuperseded() async throws {
        EngineMockURLProtocol.reset()
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" { return (200, Data("{\"accepted_at\":123}".utf8), nil) }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" { return (200, Data("{\"rows\":[]}".utf8), nil) }
            return (200, Data("{\"changes\":[]}".utf8), nil)
        }
        let metadata = StubMetadata(); let owner = UUID()
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let positions = SwiftDataPositionStore(dbStore: db)
        let old = Position(bookId: UUID(), locator: "old", updatedAt: Date(timeIntervalSince1970: 123))
        let newer = Position(id: old.id, bookId: old.bookId, locator: "new", updatedAt: old.updatedAt.addingTimeInterval(1))
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 7, bookID: old.bookId, contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: old.bookId, userId: owner, title: "Book", author: nil, formatTypeRawValue: "epub", addedAt: .now, openedAt: nil, fileURL: "book.epub", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: .init(ownerID: owner, accountGeneration: 7))
        try await db.activateBookReading(permit: permit)
        let authority = BookScopedMutationStore(dbStore: db).publicationAuthority(permit: permit, source: BookSourceAccessPermit())
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        await metadata.failNextMarkDirty()
        #expect(try await engine.commitReaderPosition(old, authority: authority) { try await positions.upsert(old) } == .publicationDeferred)
        #expect(try await engine.commitReaderPosition(newer, authority: authority) { try await positions.upsert(newer) } == .committed)
        _ = await engine.runOnce()
        #expect(try await positions.position(for: old.bookId) == newer)
        #expect(!(await metadata.hasProtectedPositionPublication(old.bookId)))
        await db.drainBookAdmission(permit: permit)
    }

    @Test("Failed recovery survives recreated native metadata and revisits a rejected book before stale cursor")
    func rejectedRecoveryRecreatedNativeStore() async throws {
        EngineMockURLProtocol.reset()
        let owner = UUID(); let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let positions = SwiftDataPositionStore(dbStore: db)
        let container = try SyncMetadataStoreBootstrap.makeContainer(inMemory: true)
        let metadata = await SwiftDataSyncMetadataStore.make(container: container)
        let local = Position(bookId: UUID(), locator: "rejected", updatedAt: Date(timeIntervalSince1970: 123))
        let winner = Position(bookId: local.bookId, locator: "winner", updatedAt: local.updatedAt)
        try await positions.upsert(local)
        try await metadata.markDirty(entityId: local.bookId, kind: .position)
        let enteredPush = DispatchSemaphore(value: 0); let resumePush = DispatchSemaphore(value: 0)
        defer { resumePush.signal() }
        EngineMockURLProtocol.handler = { request in
            if request.url?.path == "/api/sync/push" {
                enteredPush.signal(); resumePush.wait()
                return (200, Data("{\"accepted_at\":123,\"accepted\":false}".utf8), nil)
            }
            if request.url?.query?.contains("scope=full") == true { return (500, Data(), nil) }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" { return (200, Data("{\"rows\":[]}".utf8), nil) }
            return (200, Data("{\"changes\":[]}".utf8), nil)
        }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        let waveTask = Task { await engine.runOnce() }
        await Task.detached { enteredPush.wait() }.value
        try await metadata.saveCursorState(.init(scope: .recovery, cursor: "stale-prefix", accountGeneration: 0))
        resumePush.signal()
        let failedWave = await waveTask.value
        #expect(failedWave.errors.contains { $0.hasPrefix("position.recovery:") })
        #expect(try await metadata.recoveryState()?.reason == .rejectedPosition)
        #expect(try await metadata.cursorState(for: .recovery) == nil)
        #expect(try await metadata.dirtyAt(entityId: local.bookId, kind: .position) == nil)
        let change = SyncChange(kind: "position", id: winner.id, payload: try SyncPayloadCodec.encodePosition(winner), updatedAt: winner.updatedAt, deleted: false)
        let data = try JSONEncoder().encode(change)
        let encoded = try #require(String(data: data, encoding: .utf8))
        EngineMockURLProtocol.handler = { request in
            #expect(request.url?.query?.contains("stale-prefix") != true)
            if request.url?.query?.contains("scope=full") == true {
                return (200, Data("{\"changes\":[\(encoded)],\"projection_complete\":true}".utf8), nil)
            }
            if request.url?.path == "/api/sync/conversations" || request.url?.path == "/api/sync/messages" { return (200, Data("{\"rows\":[]}".utf8), nil) }
            return (200, Data("{\"changes\":[]}".utf8), nil)
        }
        let recreated = await SwiftDataSyncMetadataStore.make(container: container)
        #expect(try await recreated.recoveryState()?.reason == .rejectedPosition)
        let nextEngine = makeEngine(metadata: recreated, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        let repaired = await nextEngine.runOnce()
        #expect(repaired.errors.isEmpty)
        let row = try #require(try await positions.position(for: local.bookId))
        #expect(row.id == local.id)
        #expect(row.locator == winner.locator)
        #expect(try await recreated.recoveryState() == nil)
    }

    @Test("Native finite authority drains entered publication then rejects revoked source/account", arguments: ["source", "account"])
    func nativeRevocationDuringPublication(_ revoke: String) async throws {
        let owner = UUID(); let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let positions = SwiftDataPositionStore(dbStore: db)
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        let position = Position(bookId: UUID(), locator: "durable", updatedAt: Date(timeIntervalSince1970: 123))
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 7, bookID: position.bookId, contentRevision: UUID())
        let account = AccountMutationPermit(ownerID: owner, accountGeneration: 7)
        try await db.write { context in
            context.insert(BookEntity(id: position.bookId, userId: owner, title: "Book", author: nil, formatTypeRawValue: "epub", addedAt: .now, openedAt: nil, fileURL: "book.epub", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: account)
        try await db.activateBookReading(permit: permit)
        let invalidation = BookSourceInvalidationSignal()
        let authority = BookScopedMutationStore(dbStore: db).publicationAuthority(permit: permit, source: BookSourceAccessPermit()) {
            if invalidation.isInvalidated { throw BookSourceAccessError.revoked }
        }
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeEngine(metadata: metadata, bookStore: StubBookStore(), positionStore: positions,
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage, ownerID: owner)
        let pause = CommitPause()
        let committed = Task {
            try await engine.commitReaderPosition(position, authority: authority) {
                try await positions.upsert(position)
                await pause.enter()
            }
        }
        await pause.waitUntilEntered()
        let revocation: Task<Void, Error>?
        if revoke == "source" { invalidation.invalidate(); revocation = nil }
        else {
            db.closeAccountAdmission(permit: account)
            revocation = Task { try await db.revokeAccountMutation(permit: account) }
        }
        #expect(try await positions.position(for: position.bookId) == position)
        #expect(try await metadata.dirtyAt(entityId: position.bookId, kind: .position) == nil)
        await pause.resume()
        // The operation entered while current and retains finite admission
        // until mark + queue finish; revocation fences all future admissions.
        #expect(try await committed.value == .committed)
        try await revocation?.value
        let later = Position(id: position.id, bookId: position.bookId, locator: "must-refuse", updatedAt: position.updatedAt.addingTimeInterval(1))
        await #expect(throws: (any Error).self) {
            try await engine.commitReaderPosition(later, authority: authority) { try await positions.upsert(later) }
        }
        #expect(try await positions.position(for: position.bookId) == position)
        #expect(try await metadata.pendingCount() == 1)
        await db.drainBookAdmission(permit: permit)
        await db.drainAccountAdmission(permit: account)
    }

    private struct RecoverySource: BookSourceResolving {
        let source: ManagedBookSource
        func acquireReadableSource(for book: Book) async throws -> BookSourceLease { throw CancellationError() }
        func managedSource(for book: Book) async throws -> ManagedBookSource? { book.id == source.bookID ? source : nil }
        func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
            guard let result = try await managedSource(for: book) else { throw CancellationError() }
            return result
        }
    }

    @Test("Recovery and closed-parent replay reach upload only after successful inbound", arguments: ["missing", "closed", "malformed", "httpFailure"])
    func readinessRecoveryHonorsInboundBarrier(mode: String) async throws {
        EngineMockURLProtocol.reset()
        let owner = UUID()
        let books = StubBookStore(), positions = StubPositionStore(), highlights = StubHighlightStore()
        let metadata = try await SyncMetadataStoreBootstrap.makeStore(inMemory: true)
        let (storage, root) = try await makeFileStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(userId: owner, title: "Recover import", formatType: .epub, fileURL: "import.epub")
        await books.seed(book)
        let url = root.appendingPathComponent(book.fileURL)
        let bytes = Data("verified managed bytes".utf8)
        try bytes.write(to: url)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: owner,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            version: ManagedFileVersion(byteCount: Int64(bytes.count), modificationDate: .distantPast,
                fileIdentifier: nil, materializationRevision: UUID()))
        let source = ManagedBookSource(bookID: book.id, url: url, fingerprint: fingerprint,
            readingPermit: BookReadingPermit(ownerID: owner, accountGeneration: 1, bookID: book.id,
                contentRevision: fingerprint.version.materializationRevision))
        let policy = BookReadinessPolicy(bookStore: books, positionStore: positions, highlightStore: highlights,
            bookmarkStore: EngineStubBookmarkStore(), conversationStore: StubConversationStore(), messageStore: StubMessageStore(),
            chapterIndexes: nil, metadataStore: metadata, sourceResolver: RecoverySource(source: source),
            currentUserID: { owner }, revalidateManagedSource: { _, captured in captured == source })
        let closedID = UUID()
        try await metadata.applyLocalBookTombstone(closedID, mutation: {})
        let closedDirty = try await metadata.dirtyAt(entityId: closedID, kind: .book)
        #expect(try await metadata.acknowledgeTombstoneIfUnchanged(entityId: closedID, kind: .book,
            expectedDirtyAt: closedDirty, lastSyncedAt: .distantPast, remoteEtag: nil))
        let stale = Position(bookId: closedID, locator: "closed", updatedAt: Date(timeIntervalSince1970: 100))
        let valid = Position(bookId: book.id, locator: "valid", updatedAt: Date(timeIntervalSince1970: 101))
        let eventChanges: [SyncChange]
        if mode == "closed" || mode == "malformed" {
            eventChanges = [SyncChange(kind: "position", id: stale.id,
                payload: mode == "malformed" ? SyncOpaqueJSON(data: Data("{}".utf8)) : try SyncPayloadCodec.encodePosition(stale),
                updatedAt: stale.updatedAt, deleted: false),
                SyncChange(kind: "position", id: valid.id, payload: try SyncPayloadCodec.encodePosition(valid), updatedAt: valid.updatedAt, deleted: false)]
        } else { eventChanges = [] }
        let encoded = String(decoding: try JSONEncoder().encode(eventChanges), as: UTF8.self)
        let eventBody = Data("{\"changes\":\(encoded),\"next_cursor\":\"ready-events\",\"cursor_scope\":\"events\",\"projection_complete\":true}".utf8)
        let presigned = "https://upload.example.invalid/import"
        EngineMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sync/events": return (200, eventBody, nil)
            case "/api/sync/changes": return mode == "httpFailure" ? (500, Data(), nil) : (200, self.emptyChangesBody(), nil)
            case "/api/sync/conversations", "/api/sync/messages": return (200, Data("{\"rows\":[]}".utf8), nil)
            case "/api/sync/upload-url": return (200, Data("{\"url\":\"\(presigned)\",\"expires_at\":946684800}".utf8), nil)
            case "/import": return (200, Data(), ["ETag": "uploaded"])
            case "/api/sync/push": return (200, Data("{\"accepted_at\":946684800,\"accepted\":true}".utf8), nil)
            default: return (404, Data(), nil)
            }
        }
        let session = makeSession(), client = makeWorkerClient(session: session)
        let uploader = BookUploader(workerClient: client, metadataStore: metadata, fileStorage: storage,
            urlSession: session, userIdProvider: { "test-user" },
            managedSourceProvider: { _ in BookUploadSource(url: source.url, fingerprint: source.fingerprint, readingPermit: source.readingPermit) },
            persistServerAcceptance: { _, _, _ in true })
        let engine = makeEngine(metadata: metadata, bookStore: books, positionStore: positions, highlightStore: highlights,
            workerClient: client, fileStorage: storage, ownerID: owner, bookReadinessPolicy: policy, bookUploaderOverride: uploader)
        let wave = await engine.runOnce()
        let succeeds = mode == "missing" || mode == "closed"
        #expect(wave.booksUploaded == (succeeds ? 1 : 0))
        #expect(wave.errors.isEmpty == succeeds)
        #expect(EngineMockURLProtocol.capturedSnapshot().contains { $0.url?.path == "/api/sync/upload-url" } == succeeds)
        #expect(try await metadata.isTombstone(entityId: closedID, kind: .book))
        #expect(try await positions.position(for: closedID) == nil)
        if mode == "closed" {
            #expect(try await positions.position(for: book.id) == valid)
            #expect(try await metadata.cursorState(for: .events)?.cursor == "ready-events")
            #expect(try await metadata.remoteSeenAt(entityId: closedID, kind: .position) == stale.updatedAt)
        }
        if mode == "malformed" {
            #expect(try await metadata.cursorState(for: .events) == nil)
            #expect(try await positions.position(for: book.id) == nil)
        }
        if !succeeds { #expect(try await metadata.dirtyAt(entityId: book.id, kind: .book) == nil) }
    }

    private actor ReadinessConsentProbe: WorkerDataUseConsentProvider {
        var calls = 0
        let firstGate: CommitPause
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        init(gate: CommitPause) { firstGate = gate }
        func hasCurrentDataUseConsent() async -> Bool {
            calls += 1
            let ready = waiters.filter { $0.0 <= calls }
            waiters.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
            if calls == 1 { await firstGate.enter() }
            return false
        }
        func waitForCalls(_ count: Int) async {
            if calls >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func count() -> Int { calls }
    }

    @Test("Managed readiness defers graph binding and requests a follow-up without UI")
    func managedReadyDispatcherSchedulesAfterGraphBinding() async throws {
        let owner = UUID(), generation: UInt64 = 17
        let dispatcher = BookManagedReadySyncDispatcher(currentOwnerID: { owner }, currentGeneration: { generation })
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: generation, bookID: UUID(), attemptID: UUID())
        await dispatcher.managedReady(token)
        let consent = ReadinessConsentProbe(gate: CommitPause())
        // Use a separate consent gate to hold a real engine wave without any network work.
        let (storage, _) = try await makeFileStorage()
        let engine = makeEngine(metadata: StubMetadata(), bookStore: StubBookStore(), positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage,
            dataUseConsentProvider: consent, ownerID: owner)
        await dispatcher.configure(engine: engine)
        await consent.waitForCalls(1)
        await dispatcher.managedReady(token)
        await dispatcher.managedReady(token)
        #expect(await consent.count() == 1)
        await consent.firstGate.resume()
        await consent.waitForCalls(2)
    }

    @Test("Managed readiness rejects stale account and generation tokens")
    func managedReadyDispatcherRejectsStaleTokens() async throws {
        let owner = UUID(), generation: UInt64 = 17
        let consent = ReadinessConsentProbe(gate: CommitPause())
        let dispatcher = BookManagedReadySyncDispatcher(currentOwnerID: { owner }, currentGeneration: { generation })
        await dispatcher.managedReady(BookMaterializationToken(ownerID: UUID(), accountGeneration: generation, bookID: UUID(), attemptID: UUID()))
        await dispatcher.managedReady(BookMaterializationToken(ownerID: owner, accountGeneration: generation - 1, bookID: UUID(), attemptID: UUID()))
        let (storage, _) = try await makeFileStorage()
        let engine = makeEngine(metadata: StubMetadata(), bookStore: StubBookStore(), positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(), workerClient: makeWorkerClient(session: makeSession()), fileStorage: storage,
            dataUseConsentProvider: consent, ownerID: owner)
        await dispatcher.configure(engine: engine)
        #expect(await consent.count() == 0)
    }

}
