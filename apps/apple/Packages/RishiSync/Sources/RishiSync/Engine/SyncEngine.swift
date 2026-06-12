import Foundation
import os.signpost
import RishiAPI
import RishiCore
import RishiLibrary
import RishiLogging

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
        public var errors: [String] = []

        public init() {}
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
    private let fetcher: RemoteChangeFetcher
    private let applier: ChangeApplier

    // Phase 16-05 — chat inbound surface. Fetchers pull rows; the engine
    // drives upserts via the stores directly (bypassing ChangeApplier).
    private let conversationsFetcher: ConversationsFetcher
    private let messagesFetcher: MessagesFetcher
    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private let chatRefreshDelegate: (any ChatSyncRefreshDelegate)?

    private var debouncer: PositionDebouncer!
    private var status: SyncStatus?

    public init(
        config: SyncEngineConfig = .init(),
        queue: SyncQueue,
        metadataStore: any SyncMetadataStore,
        bookStore: any BookStore,
        bookUploader: BookUploader,
        positionUploader: PositionUploader,
        highlightUploader: HighlightUploader,
        conversationUploader: ConversationUploader,
        messageUploader: MessageUploader,
        fetcher: RemoteChangeFetcher,
        applier: ChangeApplier,
        conversationsFetcher: ConversationsFetcher,
        messagesFetcher: MessagesFetcher,
        conversationStore: any ConversationStore,
        messageStore: any MessageStore,
        chatRefreshDelegate: (any ChatSyncRefreshDelegate)? = nil
    ) {
        self.config = config
        self.queue = queue
        self.metadataStore = metadataStore
        self.bookStore = bookStore
        self.bookUploader = bookUploader
        self.positionUploader = positionUploader
        self.highlightUploader = highlightUploader
        self.conversationUploader = conversationUploader
        self.messageUploader = messageUploader
        self.fetcher = fetcher
        self.applier = applier
        self.conversationsFetcher = conversationsFetcher
        self.messagesFetcher = messagesFetcher
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.chatRefreshDelegate = chatRefreshDelegate

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
            await refreshPendingCount()
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
            await refreshPendingCount()
        } catch {
            Log.error("sync.markHighlightDirty.failed", error: error)
        }
    }

    /// CHAT-04 — flag a Conversation row for outbound sync. Called by
    /// `AppChatDirtyHook` (app layer) after `RishiChatService` persists a
    /// new/updated conversation.
    public func markConversationDirty(_ id: ConversationID) async {
        do {
            try await metadataStore.markDirty(entityId: id, kind: .conversation)
            await queue.enqueue(SyncQueueItem(entityId: id, kind: .conversation))
            await refreshPendingCount()
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
            await refreshPendingCount()
        } catch {
            Log.error("sync.markMessageDirty.failed", error: error)
        }
    }

    /// Called by `PositionDebouncer` after the per-bookId window closes.
    fileprivate func commitPositionDirty(_ bookId: BookID) async {
        do {
            try await metadataStore.markDirty(entityId: bookId, kind: .position)
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .position))
            await refreshPendingCount()
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
        setRunning(true)

        // 0. Hydrate the in-memory queue from sync_metadata.
        do {
            try await queue.refreshFromStore()
        } catch {
            wave.errors.append("queue.refresh: \(error)")
        }

        // 1. Inbound — fetch + apply remote changes.
        do {
            let changes = try await fetcher.fetch()
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

        // 1b. Inbound — Phase 16-05: dedicated chat-sync pulls. The legacy
        //     ChangeApplier `.conversation` / `.message` branches stay as a
        //     defensive markClean no-op (regression-guarded by tests); the
        //     real merge happens here so the engine can drive the stores
        //     directly without widening ChangeApplier's dep surface.
        var chatRowsApplied = 0
        do {
            let convos = try await conversationsFetcher.fetch()
            for convo in convos {
                // LWW: drop remote if local is newer-or-equal.
                if let local = try await conversationStore.conversation(convo.id),
                   local.updatedAt >= convo.updatedAt {
                    wave.conflicts += 1
                    continue
                }
                try await conversationStore.upsert(convo)
                try await metadataStore.markClean(
                    entityId: convo.id,
                    kind: .conversation,
                    lastSyncedAt: convo.updatedAt,
                    remoteEtag: nil
                )
                wave.applied += 1
                chatRowsApplied += 1
            }
        } catch {
            wave.errors.append("conversations.fetch: \(error)")
        }

        do {
            let msgs = try await messagesFetcher.fetch()
            for msg in msgs {
                // Messages are append-only locally — server is canonical;
                // unconditional upsert keyed by id is the right move.
                try await messageStore.upsert(msg)
                try await metadataStore.markClean(
                    entityId: msg.id,
                    kind: .message,
                    lastSyncedAt: msg.createdAt,
                    remoteEtag: nil
                )
                wave.applied += 1
                chatRowsApplied += 1
            }
        } catch {
            wave.errors.append("messages.fetch: \(error)")
        }

        // 2. Outbound — drain queue with per-kind buckets so a book-only
        //    drain doesn't accidentally swallow position items as collateral.
        let limit = config.batchLimit
        let drained = await queue.dequeueNext(limit: limit)
        var booksBucket: [SyncQueueItem] = []
        var positionsBucket: [SyncQueueItem] = []
        var highlightsBucket: [SyncQueueItem] = []
        var conversationsBucket: [SyncQueueItem] = []
        var messagesBucket: [SyncQueueItem] = []
        for item in drained {
            switch item.kind {
            case .book:         booksBucket.append(item)
            case .position:     positionsBucket.append(item)
            case .highlight:    highlightsBucket.append(item)
            case .conversation: conversationsBucket.append(item)
            case .message:      messagesBucket.append(item)
            }
        }

        // 2a. Books — one upload per item (no batching API today).
        for item in booksBucket {
            do {
                if let book = try await bookStore.book(item.entityId) {
                    try await bookUploader.upload(book)
                    wave.booksUploaded += 1
                } else {
                    // Local row gone — drop the dirty mark.
                    try await metadataStore.forget(entityId: item.entityId, kind: .book)
                }
            } catch {
                wave.errors.append("book.upload: \(error)")
                await queue.enqueue(item) // re-enqueue for the next wave
            }
        }

        // 2b. Positions — batch push.
        if !positionsBucket.isEmpty {
            do {
                wave.positionsPushed = try await positionUploader.pushPending(items: positionsBucket)
            } catch {
                wave.errors.append("position.push: \(error)")
                for item in positionsBucket { await queue.enqueue(item) }
            }
        }

        // 2c. Highlights — batch push (live + tombstones).
        if !highlightsBucket.isEmpty {
            do {
                wave.highlightsPushed = try await highlightUploader.pushPending(items: highlightsBucket)
            } catch {
                wave.errors.append("highlight.push: \(error)")
                for item in highlightsBucket { await queue.enqueue(item) }
            }
        }

        // 2d. Conversations — batch push (Phase 16-04).
        if !conversationsBucket.isEmpty {
            do {
                wave.conversationsPushed = try await conversationUploader.pushPending(items: conversationsBucket)
            } catch {
                wave.errors.append("conversation.push: \(error)")
                for item in conversationsBucket { await queue.enqueue(item) }
            }
        }

        // 2e. Messages — batch push (Phase 16-04).
        if !messagesBucket.isEmpty {
            do {
                wave.messagesPushed = try await messageUploader.pushPending(items: messagesBucket)
            } catch {
                wave.errors.append("message.push: \(error)")
                for item in messagesBucket { await queue.enqueue(item) }
            }
        }

        // 3. Snapshot SyncStatus for the UI.
        await snapshotStatus(error: wave.errors.first)

        // 3b. Phase 16-05 — fire the chat-refresh delegate so the
        //     Conversations tab re-reads from the store after an inbound
        //     chat merge. Skipped when no chat rows were applied so the
        //     UI doesn't churn on book-only or empty waves.
        if chatRowsApplied > 0, let delegate = chatRefreshDelegate {
            await delegate.chatSyncDidMerge()
        }

        setRunning(false)

        Log.event("sync.wave.completed", level: .info, data: [
            "fetched": String(wave.fetched),
            "applied": String(wave.applied),
            "conflicts": String(wave.conflicts),
            "books_uploaded": String(wave.booksUploaded),
            "positions_pushed": String(wave.positionsPushed),
            "highlights_pushed": String(wave.highlightsPushed),
            "conversations_pushed": String(wave.conversationsPushed),
            "messages_pushed": String(wave.messagesPushed),
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

    // MARK: - Status mutations

    private func setRunning(_ running: Bool) {
        guard let status else { return }
        let now = status.snapshot()
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: now.lastSyncedAt,
            pendingCount: now.pendingCount,
            isRunning: running,
            lastError: running ? nil : now.lastError
        ))
    }

    private func refreshPendingCount() async {
        guard let status else { return }
        let count = (try? await metadataStore.pendingCount()) ?? 0
        let now = status.snapshot()
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: now.lastSyncedAt,
            pendingCount: count,
            isRunning: now.isRunning,
            lastError: now.lastError
        ))
    }

    private func snapshotStatus(error: String?) async {
        guard let status else { return }
        let cursor = try? await metadataStore.globalLastSyncedAt()
        let pending = (try? await metadataStore.pendingCount()) ?? 0
        status.apply(SyncStatusSnapshot(
            lastSyncedAt: cursor,
            pendingCount: pending,
            isRunning: false,
            lastError: error
        ))
    }
}
