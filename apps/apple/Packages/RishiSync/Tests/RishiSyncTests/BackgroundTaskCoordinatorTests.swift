// BackgroundTasks framework headers exist on macOS for source compat, but
// every type carries `@available(macOS, unavailable)` — `BGTaskRequest`,
// `BGTask`, etc. So gate the test file to iOS/Catalyst host triples where
// the symbols actually resolve.
#if canImport(BackgroundTasks) && (os(iOS) || targetEnvironment(macCatalyst))
import Testing
import Foundation
import BackgroundTasks
@testable import RishiSync
import RishiAPI
import RishiCore
import RishiLibrary

/// SYNC-05 — `BackgroundTaskCoordinator` register + schedule + launch-handler
/// routing wraps `BGTaskScheduler` behind a `Surface` protocol so unit tests
/// don't touch the real scheduler. BGTask identifiers MUST match Info.plist's
/// `BGTaskSchedulerPermittedIdentifiers` exactly.
@Suite("BackgroundTaskCoordinator — register + schedule", .serialized)
@MainActor
struct BackgroundTaskCoordinatorTests {

    private final class CapturingSurface: BackgroundTaskCoordinator.Surface, @unchecked Sendable {
        private let lock = NSLock()
        private var _registeredIdentifiers: [String] = []
        private var _submittedRequests: [BGTaskRequest] = []

        var registeredIdentifiers: [String] {
            lock.lock(); defer { lock.unlock() }
            return _registeredIdentifiers
        }
        var submittedRequests: [BGTaskRequest] {
            lock.lock(); defer { lock.unlock() }
            return _submittedRequests
        }

        @MainActor
        func register(forTaskWithIdentifier id: String, using queue: DispatchQueue?, launchHandler: @MainActor @escaping (BGTask) -> Void) -> Bool {
            lock.lock(); _registeredIdentifiers.append(id); lock.unlock()
            return true
        }

        @MainActor
        func submit(_ request: BGTaskRequest) throws {
            lock.lock(); _submittedRequests.append(request); lock.unlock()
        }
    }

    // MARK: - Minimal SyncEngine for handler-target wiring

    private static func makeNoopEngine() -> SyncEngine {
        // Build a fully-wired engine whose dependencies are no-op stubs.
        // The coordinator tests never invoke handler bodies, but we still
        // need a real SyncEngine instance for the init parameter.
        let metadata = NoopMetadata()
        let queue = SyncQueue(metadataStore: metadata)
        let bookStore = NoopBookStore()
        let positionStore = NoopPositionStore()
        let highlightStore = NoopHighlightStore()
        let client = WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: .shared,
            tokenProvider: StaticTokenProvider("test-token")
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-bg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStorage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])

        let bookUploader = BookUploader(workerClient: client, metadataStore: metadata, fileStorage: fileStorage, userIdProvider: { "test-user" })
        let positionUploader = PositionUploader(workerClient: client, positionStore: positionStore, bookStore: bookStore, metadataStore: metadata)
        let highlightUploader = HighlightUploader(workerClient: client, highlightStore: highlightStore, metadataStore: metadata)
        let conversationUploader = ConversationUploader(workerClient: client, conversationStore: NoopConversationStore(), metadataStore: metadata)
        let messageUploader = MessageUploader(workerClient: client, messageStore: NoopMessageStore(), metadataStore: metadata)
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

    private actor NoopMetadata: SyncMetadataStore {
        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {}
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {}
    }
    private actor NoopBookStore: BookStore {
        func books(for userId: UserID) async throws -> [Book] { [] }
        func book(_ id: BookID) async throws -> Book? { nil }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}
    }
    private actor NoopPositionStore: PositionStore {
        func position(for bookId: BookID) async throws -> Position? { nil }
        func upsert(_ position: Position) async throws {}
        func delete(_ id: PositionID) async throws {}
    }
    private actor NoopHighlightStore: HighlightStore {
        func highlights(for bookId: BookID) async throws -> [Highlight] { [] }
        func highlight(_ id: HighlightID) async throws -> Highlight? { nil }
        func upsert(_ highlight: Highlight) async throws {}
        func delete(_ id: HighlightID) async throws {}
    }
    private actor NoopConversationStore: ConversationStore {
        func conversations(for userId: UserID) async throws -> [Conversation] { [] }
        func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
        func upsert(_ conversation: Conversation) async throws {}
        func delete(_ id: ConversationID) async throws {}
    }
    private actor NoopMessageStore: MessageStore {
        func messages(for conversationId: ConversationID) async throws -> [Message] { [] }
        func message(_ id: MessageID) async throws -> Message? { nil }
        func upsert(_ message: Message) async throws {}
        func delete(_ id: MessageID) async throws {}
    }

    // MARK: - Tests

    @Test("register() calls surface.register twice with the two known identifiers")
    func registerInvokesBothIdentifiers() async throws {
        let surface = CapturingSurface()
        let engine = Self.makeNoopEngine()
        let coordinator = BackgroundTaskCoordinator(engine: engine, surface: surface)
        _ = coordinator.register()
        #expect(surface.registeredIdentifiers.count == 2)
        #expect(surface.registeredIdentifiers.contains("org.fidexa.rishi.sync.processing"))
        #expect(surface.registeredIdentifiers.contains("org.fidexa.rishi.sync.refresh"))
    }

    @Test("scheduleAll submits exactly 1 BGProcessingTaskRequest + 1 BGAppRefreshTaskRequest")
    func scheduleAllSubmitsBoth() async throws {
        let surface = CapturingSurface()
        let engine = Self.makeNoopEngine()
        let coordinator = BackgroundTaskCoordinator(engine: engine, surface: surface)
        coordinator.scheduleAll()
        #expect(surface.submittedRequests.count == 2)
        let processingCount = surface.submittedRequests.filter { $0 is BGProcessingTaskRequest }.count
        let refreshCount = surface.submittedRequests.filter { $0 is BGAppRefreshTaskRequest }.count
        #expect(processingCount == 1)
        #expect(refreshCount == 1)
    }

    @Test("BGProcessingTaskRequest declares requiresNetworkConnectivity=true")
    func processingRequestRequiresNetwork() async throws {
        let surface = CapturingSurface()
        let engine = Self.makeNoopEngine()
        let coordinator = BackgroundTaskCoordinator(engine: engine, surface: surface)
        coordinator.scheduleAll()
        let processing = surface.submittedRequests.compactMap { $0 as? BGProcessingTaskRequest }.first
        #expect(processing != nil)
        #expect(processing?.requiresNetworkConnectivity == true)
        #expect(processing?.identifier == "org.fidexa.rishi.sync.processing")
    }

    @Test("BGAppRefreshTaskRequest declares earliestBeginDate > now")
    func refreshRequestEarliestBeginDateInFuture() async throws {
        let surface = CapturingSurface()
        let engine = Self.makeNoopEngine()
        let config = SyncEngineConfig(backgroundRefreshInterval: 60.0)
        let coordinator = BackgroundTaskCoordinator(engine: engine, config: config, surface: surface)
        let scheduledAt = Date()
        coordinator.scheduleAll()
        let refresh = surface.submittedRequests.compactMap { $0 as? BGAppRefreshTaskRequest }.first
        #expect(refresh != nil)
        #expect(refresh?.identifier == "org.fidexa.rishi.sync.refresh")
        let earliest = refresh?.earliestBeginDate
        #expect(earliest != nil)
        // Should be roughly scheduledAt + 60s (within a 5s margin for slow CI).
        if let earliest {
            let delta = earliest.timeIntervalSince(scheduledAt)
            #expect(delta > 55 && delta < 120)
        }
    }
}

#endif
