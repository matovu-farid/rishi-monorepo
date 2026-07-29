import Foundation
import os.signpost





/// Phase 19 Plan 19-08 (F-P2-04) — file-static signposter for sync waves.
/// Every `runOnce()` call (BGTaskScheduler-triggered, silent-push-triggered,
/// or user-Sync-Now-triggered) emits a `sync.wave` interval so Instruments
/// can attribute the cost of fetch + apply + outbound drain. `OSSignposter`
/// is `Sendable` so the actor-isolated `runOnce()` body uses it without an
/// extra hop. Pure additive; the engine's behavior is unchanged.
private let syncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "sync"
)

/// Owns the sync loop and serializes all sync work through actor isolation.
///
/// Public surface is intentionally narrow:
///   - `runOnce()` — full sync wave (fetch + apply + drain queue)
///   - `syncNow()` — user-facing SYNC-08 entry; wraps `runOnce`
///   - `markBookDirty` / `markPositionDirty` (debounced) / `markHighlightDirty`
///   - `bind(status:)` — hook the @Observable SyncStatus from AppDependencies
///
/// SYNC-03's 1s debounce on position writes lives in `PositionDebouncer`;
/// commits hop back through `commitPositionDirty` so all state mutations
/// (queue, metadata store, SyncStatus) stay actor-isolated to the engine.
public actor SyncEngine {

    /// Result snapshot for one `runOnce` wave.
    public struct Wave: Sendable, Equatable {
        public var fetched: Int = 0
        public var applied: Int = 0
        public var conflicts: Int = 0
        public var skipped: Int = 0
        public var booksUploaded: Int = 0
        public var positionsPushed: Int = 0
        public var highlightsPushed: Int = 0
        public var conversationsPushed: Int = 0
        public var messagesPushed: Int = 0
        public var bookmarksPushed: Int = 0
        public var errors: [String] = []

        public init() {}
    }

    /// Composition-only dependency bundle. The engine owns orchestration;
    /// callers provide one assembled sync graph instead of exposing every
    /// leaf dependency through the engine initializer.
    public struct Dependencies {
        public let queue: SyncQueue
        public let metadataStore: any SyncMetadataStore
        public let bookStore: any BookStore
        public let bookUploader: BookUploader
        public let positionUploader: PositionUploader
        public let highlightUploader: HighlightUploader
        public let conversationUploader: ConversationUploader
        public let messageUploader: MessageUploader
        public let bookmarkUploader: BookmarkUploader
        public let fetcher: RemoteChangeFetcher
        public let applier: ChangeApplier
        public let conversationsFetcher: ConversationsFetcher
        public let messagesFetcher: MessagesFetcher
        public let conversationStore: any ConversationStore
        public let messageStore: any MessageStore

        public init(
            queue: SyncQueue,
            metadataStore: any SyncMetadataStore,
            bookStore: any BookStore,
            bookUploader: BookUploader,
            positionUploader: PositionUploader,
            highlightUploader: HighlightUploader,
            conversationUploader: ConversationUploader,
            messageUploader: MessageUploader,
            bookmarkUploader: BookmarkUploader,
            fetcher: RemoteChangeFetcher,
            applier: ChangeApplier,
            conversationsFetcher: ConversationsFetcher,
            messagesFetcher: MessagesFetcher,
            conversationStore: any ConversationStore,
            messageStore: any MessageStore
        ) {
            self.queue = queue
            self.metadataStore = metadataStore
            self.bookStore = bookStore
            self.bookUploader = bookUploader
            self.positionUploader = positionUploader
            self.highlightUploader = highlightUploader
            self.conversationUploader = conversationUploader
            self.messageUploader = messageUploader
            self.bookmarkUploader = bookmarkUploader
            self.fetcher = fetcher
            self.applier = applier
            self.conversationsFetcher = conversationsFetcher
            self.messagesFetcher = messagesFetcher
            self.conversationStore = conversationStore
            self.messageStore = messageStore
        }
    }

    private let config: SyncEngineConfig
    private let queue: SyncQueue
    private let metadataStore: any SyncMetadataStore
    private let bookStore: any BookStore

    private let bookUploader: BookUploader
    private let positionUploader: PositionUploader
    private let highlightUploader: HighlightUploader
    private let conversationUploader: ConversationUploader
    private let messageUploader: MessageUploader
    private let bookmarkUploader: BookmarkUploader
    private let fetcher: RemoteChangeFetcher
    private let applier: ChangeApplier

    // Phase 16-05 — chat inbound surface. Fetchers pull rows; the engine
    // drives upserts via the stores directly (bypassing ChangeApplier).
    private let conversationsFetcher: ConversationsFetcher
    private let messagesFetcher: MessagesFetcher
    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private let chatRefreshDelegate: (any ChatSyncRefreshDelegate)?

    // Plan 34-10 (SRP) — runOnce's three responsibilities extracted into
    // focused collaborators. The engine keeps only orchestration + actor
    // isolation + debouncer lifecycle.
    private let chatInboundMerger: ChatInboundMerger
    private let outboundDrainer: OutboundDrainer
    private let statusReporter: SyncStatusReporter

    private var debouncer: PositionDebouncer!
    private var status: SyncStatus?
    private var accountGeneration = 0

    public init(
        config: SyncEngineConfig = .init(),
        dependencies: Dependencies,
        chatRefreshDelegate: (any ChatSyncRefreshDelegate)? = nil
    ) {
        let queue = dependencies.queue
        let metadataStore = dependencies.metadataStore
        let bookStore = dependencies.bookStore
        let bookUploader = dependencies.bookUploader
        let positionUploader = dependencies.positionUploader
        let highlightUploader = dependencies.highlightUploader
        let conversationUploader = dependencies.conversationUploader
        let messageUploader = dependencies.messageUploader
        let bookmarkUploader = dependencies.bookmarkUploader
        let fetcher = dependencies.fetcher
        let applier = dependencies.applier
        let conversationsFetcher = dependencies.conversationsFetcher
        let messagesFetcher = dependencies.messagesFetcher
        let conversationStore = dependencies.conversationStore
        let messageStore = dependencies.messageStore

        self.config = config
        self.queue = queue
        self.metadataStore = metadataStore
        self.bookStore = bookStore
        self.bookUploader = bookUploader
        self.positionUploader = positionUploader
        self.highlightUploader = highlightUploader
        self.conversationUploader = conversationUploader
        self.messageUploader = messageUploader
        self.bookmarkUploader = bookmarkUploader
        self.fetcher = fetcher
        self.applier = applier
        self.conversationsFetcher = conversationsFetcher
        self.messagesFetcher = messagesFetcher
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.chatRefreshDelegate = chatRefreshDelegate

        // Plan 34-10 (SRP) — assemble the runOnce collaborators from the
        // already-stored dependencies. No new init params; uploaders/fetchers/
        // stores are reused as-is so behavior is unchanged.
        self.chatInboundMerger = ChatInboundMerger(
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            metadataStore: metadataStore
        )
        self.outboundDrainer = OutboundDrainer(dependencies: .init(
            queue: queue,
            bookStore: bookStore,
            metadataStore: metadataStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            conversationUploader: conversationUploader,
            messageUploader: messageUploader,
            bookmarkUploader: bookmarkUploader
        ))
        self.statusReporter = SyncStatusReporter(metadataStore: metadataStore)

        // PositionDebouncer's commit closure hops back into this actor so
        // queue + metadata + status mutations stay isolated. self isn't
        // available yet for `[weak self]` — use a holder that the actor's
        // init fills in via a one-shot assignment.
        let holder = EngineHolder()
        self.debouncer = PositionDebouncer(window: config.positionDebounceWindow) { bookId in
            await holder.engine?.commitPositionDirty(bookId)
        }
        holder.engine = self
    }

    /// Late-bound back-reference so `PositionDebouncer.commit` can call back
    /// into the engine without capturing `self` mid-init.
    ///
    /// @unchecked Sendable justified: holds a mutable `weak var engine`
    /// that is assigned exactly once at init-end on the actor's executor
    /// and only read from the debouncer's commit closure thereafter.
    private final class EngineHolder: @unchecked Sendable {
        weak var engine: SyncEngine?
    }

    // MARK: - Public binding

    public func bind(status: SyncStatus) {
        self.status = status
    }

    // MARK: - Dirty marks

    public func markBookDirty(_ bookId: BookID) async {
        do {
            try await metadataStore.markDirty(entityId: bookId, kind: .book)
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .book))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markBookDirty.failed", error: error)
        }
    }

    public func markPositionDirty(_ bookId: BookID) async {
        await debouncer.mark(bookId)
    }

    public func markHighlightDirty(_ highlightId: HighlightID) async {
        do {
            try await metadataStore.markDirty(entityId: highlightId, kind: .highlight)
            await queue.enqueue(SyncQueueItem(entityId: highlightId, kind: .highlight))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markHighlightDirty.failed", error: error)
        }
    }

    /// Phase 37-08 (BMK-05) — flag a Bookmark row for outbound sync. Called by
    /// the EPUB/PDF bookmark toggle sites after `bookmarkStore.upsert`/`delete`.
    public func markBookmarkDirty(_ id: BookmarkID) async {
        do {
            try await metadataStore.markDirty(entityId: id, kind: .bookmark)
            await queue.enqueue(SyncQueueItem(entityId: id, kind: .bookmark))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markBookmarkDirty.failed", error: error)
        }
    }

    /// CHAT-04 — flag a Conversation row for outbound sync. Called by
    /// `AppChatDirtyHook` (app layer) after `RishiChatService` persists a
    /// new/updated conversation.
    public func markConversationDirty(_ id: ConversationID) async {
        do {
            try await metadataStore.markDirty(entityId: id, kind: .conversation)
            await queue.enqueue(SyncQueueItem(entityId: id, kind: .conversation))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markConversationDirty.failed", error: error)
        }
    }

    /// CHAT-04 — flag a Message row for outbound sync. Called by
    /// `AppChatDirtyHook` (app layer) after `RishiChatService` persists a
    /// user / assistant message.
    public func markMessageDirty(_ id: MessageID) async {
        do {
            try await metadataStore.markDirty(entityId: id, kind: .message)
            await queue.enqueue(SyncQueueItem(entityId: id, kind: .message))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markMessageDirty.failed", error: error)
        }
    }

    /// Called by `PositionDebouncer` after the per-bookId window closes.
    fileprivate func commitPositionDirty(_ bookId: BookID) async {
        do {
            try await metadataStore.markDirty(entityId: bookId, kind: .position)
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .position))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.commitPositionDirty.failed", error: error)
        }
    }

    // MARK: - Sync wave

    /// One full sync wave: refresh queue → fetch + apply remote → drain
    /// outbound queue by kind → snapshot status.
    @discardableResult
    public func runOnce() async -> Wave {
        // Phase 19 Plan 19-08 (F-P2-04) — wrap the full sync wave so the
        // BGTask + silent-push + manual paths share one Instruments
        // interval. The endInterval is in a `defer` so errors thrown
        // mid-wave (none today; runOnce never rethrows) would still close
        // the trace cleanly. Pure additive.
        let signpostState = syncSignposter.beginInterval("sync.wave")
        defer { syncSignposter.endInterval("sync.wave", signpostState) }
        var wave = Wave()
        let waveGeneration = accountGeneration
        statusReporter.setRunning(true, on: status)

        // 0. Hydrate the in-memory queue from sync_metadata.
        do {
            try await queue.refreshFromStore()
        } catch {
            wave.errors.append("queue.refresh: \(error)")
        }

        // 1. Inbound — fetch + apply remote changes.
        do {
            let changes = try await fetcher.fetch()
            guard !Task.isCancelled else {
                statusReporter.setRunning(false, on: status)
                return wave
            }
            wave.fetched = changes.count
            if !changes.isEmpty {
                let result = await applier.apply(changes)
                wave.applied = result.applied
                wave.conflicts = result.conflicts
                wave.skipped = result.skipped
                wave.errors.append(contentsOf: result.errors)
            }
        } catch {
            wave.errors.append("fetch: \(error)")
        }

        // 1b. Inbound — Phase 16-05: dedicated chat-sync pulls, delegated to
        //     ChatInboundMerger (plan 34-10). The legacy ChangeApplier
        //     `.conversation` / `.message` branches stay a defensive markClean
        //     no-op (regression-guarded by tests); the real merge runs here so
        //     the engine drives the stores directly without widening
        //     ChangeApplier's dep surface.
        let chatMerge = await chatInboundMerger.merge()
        wave.applied += chatMerge.applied
        wave.conflicts += chatMerge.conflicts
        wave.errors.append(contentsOf: chatMerge.errors)
        let chatRowsApplied = chatMerge.chatRowsApplied

        guard !Task.isCancelled else {
            statusReporter.setRunning(false, on: status)
            return wave
        }

        guard waveGeneration == accountGeneration else {
            statusReporter.setRunning(false, on: status)
            return wave
        }

        // 2. Outbound — drain the queue by kind, delegated to OutboundDrainer
        //    (plan 34-10). Per-kind buckets keep a book-only drain from
        //    swallowing position items as collateral.
        let drain = await outboundDrainer.drain(limit: config.batchLimit)
        wave.booksUploaded = drain.booksUploaded
        wave.positionsPushed = drain.positionsPushed
        wave.highlightsPushed = drain.highlightsPushed
        wave.conversationsPushed = drain.conversationsPushed
        wave.messagesPushed = drain.messagesPushed
        wave.bookmarksPushed = drain.bookmarksPushed
        wave.errors.append(contentsOf: drain.errors)

        // 3. Snapshot SyncStatus for the UI.
        await statusReporter.snapshotStatus(error: wave.errors.first, on: status)

        // 3b. Phase 16-05 — fire the chat-refresh delegate so the
        //     Conversations tab re-reads from the store after an inbound
        //     chat merge. Skipped when no chat rows were applied so the
        //     UI doesn't churn on book-only or empty waves.
        if chatRowsApplied > 0, let delegate = chatRefreshDelegate {
            await delegate.chatSyncDidMerge()
        }

        statusReporter.setRunning(false, on: status)

        Log.event("sync.wave.completed", level: .info, data: [
            "fetched": String(wave.fetched),
            "applied": String(wave.applied),
            "conflicts": String(wave.conflicts),
            "books_uploaded": String(wave.booksUploaded),
            "positions_pushed": String(wave.positionsPushed),
            "highlights_pushed": String(wave.highlightsPushed),
            "conversations_pushed": String(wave.conversationsPushed),
            "messages_pushed": String(wave.messagesPushed),
            "bookmarks_pushed": String(wave.bookmarksPushed),
            "errors": String(wave.errors.count),
        ])
        return wave
    }

    /// SYNC-08 — user-facing "Sync Now" entry.
    public func syncNow() async {
        _ = await runOnce()
    }

    /// Force all pending debounced position-marks to commit immediately
    /// (engine shutdown / app background path).
    public func flushDebounce() async {
        await debouncer.flush()
    }

    /// Invalidates queued and in-flight account work before auth state changes.
    /// A generation check prevents a wave that was suspended in network I/O
    /// from draining old-account records after sign-out.
    public func resetForAccountSwitch() async {
        accountGeneration += 1
        await debouncer.cancelAll()
        await queue.clear()
    }

    // MARK: - Status mutations
    //
    // Plan 34-10 (SRP) — the setRunning / refreshPendingCount / snapshotStatus
    // bodies moved to `SyncStatusReporter`. The engine routes through
    // `statusReporter`, passing the late-bound `status` per call.
}
