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
    private final class WaveWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Wave, Never>?
        private var cancelled = false

        func install(_ continuation: CheckedContinuation<Wave, Never>) {
            let resumeImmediately: Bool
            lock.lock()
            if cancelled {
                resumeImmediately = true
            } else {
                self.continuation = continuation
                resumeImmediately = false
            }
            lock.unlock()

            if resumeImmediately {
                continuation.resume(returning: Wave())
            }
        }

        func cancel() {
            let continuation: CheckedContinuation<Wave, Never>?
            lock.lock()
            cancelled = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: Wave())
        }

        func complete(_ wave: Wave) {
            let continuation: CheckedContinuation<Wave, Never>?
            lock.lock()
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: wave)
        }
    }


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
        public var chapterIndexesPushed: Int = 0
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
        public let chapterIndexUploader: ChapterIndexUploader
        public let fetcher: RemoteChangeFetcher
        public let applier: ChangeApplier
        public let conversationsFetcher: ConversationsFetcher
        public let messagesFetcher: MessagesFetcher
        public let conversationStore: any ConversationStore
        public let messageStore: any MessageStore
        public let dataUseConsentProvider: any WorkerDataUseConsentProvider
        public let currentUserId: @Sendable () async -> UserID?
        public let localSyncObjectBuilder: LocalSyncObjectBuilder?

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
            chapterIndexUploader: ChapterIndexUploader,
            fetcher: RemoteChangeFetcher,
            applier: ChangeApplier,
            conversationsFetcher: ConversationsFetcher,
            messagesFetcher: MessagesFetcher,
            conversationStore: any ConversationStore,
            messageStore: any MessageStore,
            dataUseConsentProvider: any WorkerDataUseConsentProvider = AlwaysAllowWorkerDataUseConsentProvider(),
            currentUserId: @escaping @Sendable () async -> UserID? = { nil },
            localSyncObjectBuilder: LocalSyncObjectBuilder? = nil
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
            self.chapterIndexUploader = chapterIndexUploader
            self.fetcher = fetcher
            self.applier = applier
            self.conversationsFetcher = conversationsFetcher
            self.messagesFetcher = messagesFetcher
            self.conversationStore = conversationStore
            self.messageStore = messageStore
            self.dataUseConsentProvider = dataUseConsentProvider
            self.currentUserId = currentUserId
            self.localSyncObjectBuilder = localSyncObjectBuilder
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
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider
    private let currentUserId: @Sendable () async -> UserID?
    private let localSyncObjectBuilder: LocalSyncObjectBuilder?

    // Plan 34-10 (SRP) — runOnce's three responsibilities extracted into
    // focused collaborators. The engine keeps only orchestration + actor
    // isolation + debouncer lifecycle.
    private let chatInboundMerger: ChatInboundMerger
    private let outboundDrainer: OutboundDrainer
    private let statusReporter: SyncStatusReporter

    private var debouncer: PositionDebouncer!
    private var status: SyncStatus?
    private var accountGeneration = 0
    private var activeWaveCount = 0
    private var resetInProgress = false
    private var activeWaveTask: Task<Wave, Never>?
    private var activeWaveToken: UUID?
    private var scheduledSyncTask: Task<Void, Never>?
    private var syncRequestPending = false
    private var waveWaiterCounts: [UUID: Int] = [:]
    private var activeDirtyMarkCount = 0

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
        let chapterIndexUploader = dependencies.chapterIndexUploader
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
        self.dataUseConsentProvider = dependencies.dataUseConsentProvider
        self.currentUserId = dependencies.currentUserId
        self.localSyncObjectBuilder = dependencies.localSyncObjectBuilder

        // Plan 34-10 (SRP) — assemble the runOnce collaborators from the
        // already-stored dependencies. No new init params; uploaders/fetchers/
        // stores are reused as-is so behavior is unchanged.
        self.chatInboundMerger = ChatInboundMerger(
            conversationsFetcher: conversationsFetcher,
            messagesFetcher: messagesFetcher,
            conversationStore: conversationStore,
            messageStore: messageStore,
            metadataStore: metadataStore,
            currentUserId: dependencies.currentUserId
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
            bookmarkUploader: bookmarkUploader,
            chapterIndexUploader: chapterIndexUploader,
            dataUseConsentProvider: dependencies.dataUseConsentProvider,
            currentUserId: dependencies.currentUserId
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

    @discardableResult
    public func markBookDirty(_ bookId: BookID) async -> Bool {
        while resetInProgress {
            await Task.yield()
        }
        activeDirtyMarkCount += 1
        defer { activeDirtyMarkCount -= 1 }
        let generation = accountGeneration
        for attempt in 0..<2 {
            do {
                try await metadataStore.markDirty(entityId: bookId, kind: .book)
                guard generation == accountGeneration, !resetInProgress else {
                    return false
                }
                await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .book))
                await statusReporter.refreshPendingCount(on: status)
                return true
            } catch {
                guard attempt == 0 else {
                    Log.error("sync.markBookDirty.failed", error: error)
                    return false
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return false
    }

    /// Persists a book deletion before its local row/file is removed. The
    /// caller must not destroy local material until this succeeds: the
    /// metadata tombstone is the durable hand-off to the outbound queue.
    public func markBookDeleted(_ bookId: BookID) async throws {
        do {
            try await metadataStore.markTombstone(entityId: bookId, kind: .book)
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .book))
            await statusReporter.refreshPendingCount(on: status)
            Log.event("sync.book.delete.queued", level: .info, data: [
                "book_id": bookId.uuidString,
            ])
            requestSync()
        } catch {
            Log.error("sync.markBookDeleted.failed", error: error)
            throw error
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

    public func markChapterIndexDirty(_ bookId: BookID) async {
        do {
            try await metadataStore.markDirty(entityId: bookId, kind: .chapterIndex)
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .chapterIndex))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.markChapterIndexDirty.failed", error: error)
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
        let generation = accountGeneration
        guard !resetInProgress else { return }
        do {
            try await metadataStore.markDirty(entityId: bookId, kind: .position)
            guard generation == accountGeneration, !resetInProgress else { return }
            await queue.enqueue(SyncQueueItem(entityId: bookId, kind: .position))
            await statusReporter.refreshPendingCount(on: status)
        } catch {
            Log.error("sync.commitPositionDirty.failed", error: error)
        }
    }

    // MARK: - Sync wave

    /// Runs one full sync wave, sharing an active wave with concurrent callers.
    /// Actor isolation alone is insufficient here because the wave suspends for
    /// network and storage awaits, allowing another caller to re-enter.
    @discardableResult
    public func runOnce() async -> Wave {
        guard !resetInProgress else { return Wave() }

        let task: Task<Wave, Never>
        let token: UUID
        if let activeWaveTask {
            task = activeWaveTask
            token = activeWaveToken!
        } else {
            token = UUID()
            task = Task { [weak self] in
                guard let self else { return Wave() }
                return await self.performRunOnce()
            }
            activeWaveTask = task
            activeWaveToken = token
            waveWaiterCounts[token] = 0
            Task { [weak self] in
                _ = await task.value
                await self?.clearActiveWave(token: token)
            }
        }
        waveWaiterCounts[token, default: 0] += 1

        let waiter = WaveWaiter()
        Task {
            waiter.complete(await task.value)
        }
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Wave, Never>) in
                waiter.install(continuation)
            }
        }, onCancel: {
            waiter.cancel()
        })
        let wasCancelled = Task.isCancelled
        let remainingWaiters = max(0, (waveWaiterCounts[token] ?? 1) - 1)
        if remainingWaiters == 0, activeWaveToken != token {
            waveWaiterCounts[token] = nil
        } else {
            waveWaiterCounts[token] = remainingWaiters
        }
        if wasCancelled, remainingWaiters == 0, activeWaveToken == token {
            task.cancel()
        }
        return wasCancelled ? Wave() : result
    }

    private func clearActiveWave(token: UUID) {
        waveWaiterCounts[token] = nil
        guard activeWaveToken == token else { return }
        activeWaveTask = nil
        activeWaveToken = nil
    }

    private struct PageConsumption: Sendable {
        var wave: Wave
        var readyForOutbound: Bool
        var aborted: Bool
        var reachedTerminalPage: Bool
        var terminalPageComplete: Bool
    }

    private func consumePages(
        scope: SyncCursorScope,
        generation: Int,
        userId: UserID?
    ) async throws -> PageConsumption {
        let storedCursor = try await metadataStore.cursorState(for: scope)
        var cursor = storedCursor?.accountGeneration == generation ? storedCursor?.cursor : nil
        var result = PageConsumption(
            wave: Wave(),
            readyForOutbound: true,
            aborted: false,
            reachedTerminalPage: false,
            terminalPageComplete: false
        )

        while true {
            let page = try await fetcher.fetchPage(scope: scope, cursor: cursor)
            result.wave.fetched += page.changes.count
            guard !Task.isCancelled else {
                result.aborted = true
                return result
            }
            if !page.changes.isEmpty {
                let applied = await applier.apply(page.changes, expectedUserId: userId)
                result.wave.applied += applied.applied
                result.wave.conflicts += applied.conflicts
                result.wave.skipped += applied.skipped
                result.wave.errors.append(contentsOf: applied.errors)
                if !applied.errors.isEmpty {
                    result.readyForOutbound = false
                    return result
                }
            }
            guard await isCurrent(generation: generation, userId: userId) else {
                result.aborted = true
                return result
            }

            if page.hasMore {
                guard let nextCursor = page.nextCursor else {
                    result.wave.errors.append("fetch: cursor page missing next_cursor")
                    result.readyForOutbound = false
                    return result
                }
                guard await isCurrent(generation: generation, userId: userId) else {
                    result.aborted = true
                    return result
                }
                try await metadataStore.saveCursorState(.init(
                    scope: scope,
                    cursor: nextCursor,
                    accountGeneration: generation
                ))
                cursor = nextCursor
            } else {
                result.reachedTerminalPage = true
                result.terminalPageComplete = page.projectionComplete
                if scope == .events {
                    // Event cursors are append-only sequence numbers. Unlike
                    // projection/recovery cursors, reaching the end does not
                    // mean the cursor should be deleted; doing so would make
                    // every later wave replay the entire event ledger.
                    if let nextCursor = page.nextCursor {
                        guard await isCurrent(generation: generation, userId: userId) else {
                            result.aborted = true
                            return result
                        }
                        try await metadataStore.saveCursorState(.init(
                            scope: scope,
                            cursor: nextCursor,
                            accountGeneration: generation
                        ))
                    }
                } else if page.projectionComplete {
                    guard await isCurrent(generation: generation, userId: userId) else {
                        result.aborted = true
                        return result
                    }
                    try await metadataStore.clearCursorState(for: scope, accountGeneration: generation)
                }
                return result
            }
        }
    }

    private func merge(_ page: PageConsumption, into wave: inout Wave) {
        wave.fetched += page.wave.fetched
        wave.applied += page.wave.applied
        wave.conflicts += page.wave.conflicts
        wave.skipped += page.wave.skipped
        wave.errors.append(contentsOf: page.wave.errors)
    }

    private func isCurrent(generation: Int, userId: UserID?) async -> Bool {
        guard !Task.isCancelled, generation == accountGeneration else { return false }
        let currentUser = await currentUserId()
        return userId == currentUser
    }

    /// Requests a background sync without waiting for its network work. Calls
    /// arriving during an active wave collapse into one follow-up wave.
    public func requestSync() {
        guard !resetInProgress else { return }
        syncRequestPending = true
        guard scheduledSyncTask == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainSyncRequests()
        }
        scheduledSyncTask = task
    }

    /// Queue a sync and wait until the requested wave (including a follow-up
    /// wave if another sync was already active) has drained. Share imports use
    /// this before reporting success so a relaunch cannot restore the
    /// pre-import server projection over a newly downloaded book.
    public func requestSyncAndWait() async {
        requestSync()
        while let task = scheduledSyncTask {
            await task.value
            if scheduledSyncTask == nil, !syncRequestPending { return }
        }
    }

    private func drainSyncRequests() async {
        while syncRequestPending {
            guard !Task.isCancelled else {
                scheduledSyncTask = nil
                return
            }
            syncRequestPending = false
            _ = await runOnce()
        }
        scheduledSyncTask = nil
    }

    /// One full sync wave: refresh queue → fetch + apply remote → drain
    /// outbound queue by kind → snapshot status.
    @discardableResult
    private func performRunOnce() async -> Wave {
        // Phase 19 Plan 19-08 (F-P2-04) — wrap the full sync wave so the
        // BGTask + silent-push + manual paths share one Instruments
        // interval. The endInterval is in a `defer` so errors thrown
        // mid-wave (none today; runOnce never rethrows) would still close
        // the trace cleanly. Pure additive.
        let signpostState = syncSignposter.beginInterval("sync.wave")
        defer { syncSignposter.endInterval("sync.wave", signpostState) }
        guard !resetInProgress, !Task.isCancelled else { return Wave() }
        activeWaveCount += 1
        defer { activeWaveCount -= 1 }
        var wave = Wave()
        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            await statusReporter.snapshotStatus(error: "Sync requires data-use consent", on: status, completedAt: nil)
            return wave
        }
        let waveGeneration = accountGeneration
        let waveUserId = await currentUserId()
        statusReporter.setRunning(true, on: status)
        var inboundReadyForOutbound = true

        // 0. Hydrate the in-memory queue from sync_metadata.
        do {
            try await queue.refreshFromStore()
        } catch {
            wave.errors.append("queue.refresh: \(error)")
            inboundReadyForOutbound = false
        }

        // 1. Inbound — consume cursor pages and commit progress only after
        // the page has been applied successfully. A separate recovery plane
        // resumes incomplete projections without resetting incremental work.
        // 1a. Consume the append-only event stream first. This is the
        // authoritative deletion/retry plane; the materialized projection
        // below remains as a compatibility and repair pass. A rolling deploy
        // may briefly have an older Worker without /events, so failure of
        // this additive plane must fall back to the projection pull.
        do {
            let eventResult = try await consumePages(
                scope: .events,
                generation: waveGeneration,
                userId: waveUserId
            )
            merge(eventResult, into: &wave)
            if eventResult.aborted {
                statusReporter.setRunning(false, on: status)
                return wave
            }
            inboundReadyForOutbound = eventResult.readyForOutbound
        } catch {
            wave.errors.append("events: \(error)")
            Log.event("sync.events.unavailable", level: .warning, data: [
                "error": String(describing: error),
            ])
        }

        do {
            let existingRecovery = try await metadataStore.recoveryState()
            let recoveryIsCurrent = existingRecovery?.accountGeneration == waveGeneration
            let pageResult: PageConsumption
            if recoveryIsCurrent {
                pageResult = try await consumePages(
                    scope: .recovery,
                    generation: waveGeneration,
                    userId: waveUserId
                )
            } else {
                if existingRecovery != nil {
                    guard await isCurrent(generation: waveGeneration, userId: waveUserId) else {
                        statusReporter.setRunning(false, on: status)
                        return wave
                    }
                    try await metadataStore.clearRecoveryState(accountGeneration: existingRecovery!.accountGeneration)
                }
                pageResult = try await consumePages(
                    scope: .incremental,
                    generation: waveGeneration,
                    userId: waveUserId
                )
            }
            merge(pageResult, into: &wave)
            if pageResult.aborted {
                statusReporter.setRunning(false, on: status)
                return wave
            }
            inboundReadyForOutbound = inboundReadyForOutbound && pageResult.readyForOutbound
            if pageResult.readyForOutbound,
               pageResult.reachedTerminalPage,
               pageResult.terminalPageComplete,
               recoveryIsCurrent {
                // A complete recovery is the promotion boundary. The next
                // incremental request establishes a new high-water mark;
                // no recovery cursor or stale incremental cursor survives it.
                guard await isCurrent(generation: waveGeneration, userId: waveUserId) else {
                    statusReporter.setRunning(false, on: status)
                    return wave
                }
                try await metadataStore.clearRecoveryState(accountGeneration: waveGeneration)
                try await metadataStore.clearCursorState(for: .incremental, accountGeneration: waveGeneration)
            } else if pageResult.readyForOutbound,
                      pageResult.reachedTerminalPage,
                      !pageResult.terminalPageComplete {
                let currentRecovery = try await metadataStore.recoveryState()
                if currentRecovery?.accountGeneration != waveGeneration {
                    guard await isCurrent(generation: waveGeneration, userId: waveUserId) else {
                        statusReporter.setRunning(false, on: status)
                        return wave
                    }
                    try await metadataStore.saveRecoveryState(.init(
                        reason: .incompleteProjection,
                        accountGeneration: waveGeneration
                    ))
                }
            }
        } catch {
            wave.errors.append("fetch: \(error)")
            inboundReadyForOutbound = false
        }

        // 1b. Inbound — Phase 16-05: dedicated chat-sync pulls, delegated to
        //     ChatInboundMerger (plan 34-10). The legacy ChangeApplier
        //     `.conversation` / `.message` branches stay a defensive markClean
        //     no-op (regression-guarded by tests); the real merge runs here so
        //     the engine drives the stores directly without widening
        //     ChangeApplier's dep surface.
        let chatMerge = await chatInboundMerger.merge(expectedUserId: waveUserId)
        wave.applied += chatMerge.applied
        wave.conflicts += chatMerge.conflicts
        wave.errors.append(contentsOf: chatMerge.errors)
        if !chatMerge.errors.isEmpty {
            inboundReadyForOutbound = false
        }
        let chatRowsApplied = chatMerge.chatRowsApplied

        guard !Task.isCancelled else {
            statusReporter.setRunning(false, on: status)
            return wave
        }

        let currentUserBeforeOutbound = await currentUserId()
        guard waveGeneration == accountGeneration,
              waveUserId == currentUserBeforeOutbound else {
            statusReporter.setRunning(false, on: status)
            return wave
        }

        guard inboundReadyForOutbound else {
            await statusReporter.snapshotStatus(error: wave.errors.first, on: status, completedAt: nil)
            statusReporter.setRunning(false, on: status)
            return wave
        }

        // 2. Outbound — drain the queue by kind, delegated to OutboundDrainer
        //    (plan 34-10). Per-kind buckets keep a book-only drain from
        //    swallowing position items as collateral.
        let drain = await outboundDrainer.drain(limit: config.batchLimit, expectedUserId: waveUserId)
        wave.booksUploaded = drain.booksUploaded
        wave.positionsPushed = drain.positionsPushed
        wave.highlightsPushed = drain.highlightsPushed
        wave.conversationsPushed = drain.conversationsPushed
        wave.messagesPushed = drain.messagesPushed
        wave.bookmarksPushed = drain.bookmarksPushed
        wave.chapterIndexesPushed = drain.chapterIndexesPushed
        wave.errors.append(contentsOf: drain.errors)

        // Final read-back is advisory. It never changes operational success;
        // upload/fetch/apply failures above remain the only wave errors.
        let currentUserBeforeVerification = await currentUserId()
        guard waveGeneration == accountGeneration,
              waveUserId == currentUserBeforeVerification else {
            statusReporter.setRunning(false, on: status)
            return wave
        }
        do {
            let page = try await fetcher.fetchPage(scope: .incremental, cursor: nil)
            let snapshot = SyncObject(
                changes: page.changes,
                remoteHash: page.snapshotHashWithoutTimestamps,
                isTruncated: page.isTruncated || !page.projectionComplete
            )
            let currentUserAfterFullSnapshot = await currentUserId()
            guard waveGeneration == accountGeneration,
                  waveUserId == currentUserAfterFullSnapshot else {
                statusReporter.setRunning(false, on: status)
                return wave
            }
            let localChanges: [SyncChange]
            if let localSyncObjectBuilder {
                let localObject = try await localSyncObjectBuilder.build()
                localChanges = localObject.changes
            } else {
                localChanges = []
            }
            let currentUserBeforeLocalProjection = await currentUserId()
            guard waveGeneration == accountGeneration,
                  waveUserId == currentUserBeforeLocalProjection else {
                statusReporter.setRunning(false, on: status)
                return wave
            }
            let localObject = SyncObject(changes: localChanges)
            let observation = try SyncIntegrityVerifier().observe(
                remote: snapshot,
                local: localObject,
                pendingLocalCount: try await metadataStore.pendingCount(),
                scope: .incremental,
                hashVersion: page.snapshotHashVersion,
                projectionComplete: page.projectionComplete
            )
            Log.event("sync.verification.observed", level: .info, data: [
                "classification": observation.classification.rawValue,
                "scope": observation.scope.rawValue,
                "diff_count": String(observation.diffPaths.count),
                "hash_version": page.snapshotHashVersion ?? "legacy",
                "projection_complete": String(page.projectionComplete),
            ])
        } catch {
            Log.event("sync.verification.unavailable", level: .warning, data: [
                "reason": "redacted",
            ])
        }

        // 3. Snapshot SyncStatus for the UI.
        await statusReporter.snapshotStatus(
            error: wave.errors.first,
            on: status,
            completedAt: wave.errors.isEmpty ? Date() : nil
        )

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
        if resetInProgress {
            while resetInProgress {
                await Task.yield()
            }
            return
        }
        resetInProgress = true
        syncRequestPending = false
        let scheduledTask = scheduledSyncTask
        scheduledSyncTask = nil
        scheduledTask?.cancel()

        let activeTask = activeWaveTask
        let activeToken = activeWaveToken
        activeWaveTask = nil
        activeWaveToken = nil
        activeTask?.cancel()
        _ = await activeTask?.value
        if let activeToken {
            waveWaiterCounts[activeToken] = nil
        }
        await scheduledTask?.value
        accountGeneration += 1
        await debouncer.cancelAll()
        while activeDirtyMarkCount > 0 {
            await Task.yield()
        }
        while activeWaveCount > 0 {
            await Task.yield()
        }
        await queue.clear()
        do {
            try await metadataStore.resetAll()
        } catch {
            Log.error("sync.reset_metadata.failed", error: error)
        }
        status?.apply(SyncStatusSnapshot(
            lastSyncedAt: nil,
            pendingCount: 0,
            isRunning: false,
            lastError: nil
        ))
        resetInProgress = false
    }

    // MARK: - Status mutations
    //
    // Plan 34-10 (SRP) — the setRunning / refreshPendingCount / snapshotStatus
    // bodies moved to `SyncStatusReporter`. The engine routes through
    // `statusReporter`, passing the late-bound `status` per call.
}
