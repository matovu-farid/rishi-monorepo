import Foundation
import Observation








/// Monotonic timing for the user-visible voice startup path. These events let
/// us compare connection changes on real devices without logging book text,
/// audio, or provider identifiers.
struct VoiceStartupTrace: Sendable {
    private let startedAt: ContinuousClock.Instant

    init(startedAt: ContinuousClock.Instant = .now) {
        self.startedAt = startedAt
    }

    func mark(_ phase: String, data: [String: String] = [:]) {
        var payload = data
        payload["phase"] = phase
        payload["elapsedMs"] = String(Int(startedAt.duration(to: .now) / .milliseconds(1)))
        Log.event("voice.startup.phase", level: .info, data: payload)
    }
}

enum VoiceStartOutcome: Equatable {
    case live
    case alreadyStarting
    case alreadyLive
    case rejected
}

/// Reader-owned voice sessions that still need lifecycle cleanup when the
/// app returns to its library boundary. Registration and draining are
/// idempotent; the presenter owns the actual teardown operation.
@MainActor
final class VoiceSessionCleanupQueue {
    private var pending: Set<ReaderSessionIdentity> = []

    var count: Int { pending.count }

    func register(_ identity: ReaderSessionIdentity) {
        pending.insert(identity)
    }

    func hasPending(asideFrom identity: ReaderSessionIdentity?) -> Bool {
        pending.contains { pendingIdentity in
            guard let identity else { return true }
            return pendingIdentity != identity
        }
    }

    func takeAll() -> [ReaderSessionIdentity] {
        let identities = Array(pending)
        pending.removeAll()
        return identities
    }
}

@MainActor
@Observable
final class VoiceSessionPresenter {

    private struct PendingPrewarm {
        let userID: UserID
        let bookID: BookID
        let client: any RealtimeClientAPI
        let task: Task<Void, Never>
    }

    let state: VoiceSessionState

    private(set) var isPresenting: Bool = false

    private(set) var failure: VoiceFailureAlert?

    private(set) var pendingFailure: VoiceFailureAlert?

    private(set) var session: RealtimeVoiceSession?

    private(set) var currentBookId: BookID?

    private(set) var pendingInitialQuote: String?

    private(set) var currentBookContext: BookContextSnapshot?
    private(set) var currentLanguage: String = "en"
    private var currentPageProvider: CurrentPageContextProvider?
    private var currentReaderSessionIdentity: ReaderSessionIdentity?
    private var startCancellationToken: UUID?
    private let cleanupQueue = VoiceSessionCleanupQueue()
    private var readerCleanupTask: Task<Bool, Never>?

    private let coordinator: AudioSessionCoordinator
    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let conversationLookup: ConversationLookup
    private let userIdProvider: @MainActor () -> UserID?
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider
    private let micGate: any MicPermissionGate

    private let bookSearch: (any BookSearch)?
    private let embedderPrewarm: (@Sendable () async -> Void)?
    private let chapterIndexResponderFactory: RealtimeVoiceSession.ChapterIndexBookContextResponderFactory?
    private let chapterIndexCoordinatorFactory: RealtimeVoiceSession.ChapterIndexCoordinatorFactory?
    private let chapterIndexContentVersionProvider: (@Sendable (BookID) async -> String?)?

    private let clientFactory: @MainActor () -> any RealtimeClientAPI
    private let keyFetcherFactory: @MainActor () -> any EphemeralKeyFetching
    private let sessionCoordinatorFactory: @MainActor () -> (any VoiceSessionCoordinating)?
    private let controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)

    let sessionRegistry: VoiceSessionRegistry

    private var bridgeTask: Task<Void, Never>?

    /// Single-flight for End (button, cover swipe, audio preemption). Cleared
    /// when local teardown finishes with no session id to deliver, or when
    /// background end delivery completes (success or informational failure).
    private var isRequestingEnd = false
    private var endFlightTask: Task<Void, Never>?

    /// Session id whose background end delivery completed successfully. Keep
    /// the persisted id until the next create succeeds, but do not send a
    /// second concurrent end for the same id during that start.
    private var recentlyDeliveredEndSessionId: String?

    /// Prevents repeated taps/lifecycle callbacks from creating overlapping
    /// server sessions while the first start is suspended on network work.
    private var isStarting = false
    private var pendingPrewarm: PendingPrewarm?

    /// Feature flag for the no-card-credit-trial voice-session flow (session
    /// create → WebRTC connect → call-ID registration → control WebSocket).
    /// Both of this plan's sibling dependencies (`RealtimeAPIAdapter.providerCallId`
    /// and `ControlWebSocketClient`) are real, landed implementations as of
    /// this writing — this flag is a staged-rollout gate, not a
    /// missing-dependency guard. See `2026-07-17-voice-session-flow-wiring.md`'s
    /// "Go/no-go signal" for the recommended flip sequence (verify this
    /// plan's own `swift test`/typecheck steps pass first, then flip to
    /// `true` for an internal build before a general rollout).
    /// `nonisolated` so `@Sendable` factories (control socket) can read the
    /// flag without hopping onto MainActor. Constant, never mutated.
    nonisolated private static let isTrialVoiceSessionFlowEnabled = true

    /// End-delivery attempts after optimistic local teardown.
    private static let endDeliveryMaxAttempts = 3
    /// Backoff between end-delivery attempts: 400ms, 800ms.
    private static let endDeliveryBackoffMs = 400
    /// Pause after a successful ledger end before creating a new session — the
    /// worker may still hold the active-session lock briefly after HTTP 200.
    private static let serverSettleAfterEndMs = 600
    private static let libraryCleanupMaxAttempts = 3
    /// Retries when POST /voice-sessions returns VOICE_SESSION_ALREADY_ACTIVE.
    private static let alreadyActiveCreateMaxAttempts = 3
    private static let alreadyActiveRetryBackoffMs = 600

    /// Ledger row id that still needs `POST …/end` before a new session can
    /// be created. Survives `clearFailure()` so Try again can unblock the server.
    private var staleRishiSessionId: String?
    private var staleRishiSessionUserID: UserID?

    /// Identifies the presenter-owned session currently allowed to update
    /// failure UI. A terminal callback can arrive after local teardown, so a
    /// callback from an older session must never clobber a newer one.
    private var activeSessionToken: UUID?

    init(
        coordinator: AudioSessionCoordinator,
        workerClient: WorkerClient,
        // Defaulted (not required) so every existing call site —
        // `ServiceGraphFactory` (updated explicitly) and the
        // `VoiceSessionPresenter*Tests.swift` files that construct this
        // type directly with their own `StubTokenProvider` — keeps
        // compiling unchanged. The default is harmless: it's only ever
        // read by `controlSocketFactory`'s closure, which itself is a
        // no-op when `Self.isTrialVoiceSessionFlowEnabled` is false unless a
        // caller also overrides `controlSocketFactory`.
        baseURL: URL = URL(string: "https://api.fidexa.org")!,
        tokenProvider: any TokenProvider = StaticTokenProvider(nil),
        dataUseConsentProvider: any WorkerDataUseConsentProvider = AlwaysAllowWorkerDataUseConsentProvider(),
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate(),
        bookSearch: (any BookSearch)? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        chapterIndexResponderFactory: RealtimeVoiceSession.ChapterIndexBookContextResponderFactory? = nil,
        chapterIndexCoordinatorFactory: RealtimeVoiceSession.ChapterIndexCoordinatorFactory? = nil,
        chapterIndexContentVersionProvider: (@Sendable (BookID) async -> String?)? = nil,
        clientFactory: (@MainActor () -> any RealtimeClientAPI)? = nil,
        keyFetcherFactory: (@MainActor () -> any EphemeralKeyFetching)? = nil,
        sessionCoordinatorFactory: (@MainActor () -> (any VoiceSessionCoordinating)?)? = nil,
        controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)? = nil,
        sessionRegistry: VoiceSessionRegistry? = nil
    ) {
        self.state = VoiceSessionState()
        self.coordinator = coordinator
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.userIdProvider = userIdProvider
        self.dirtyHook = dirtyHook
        self.dataUseConsentProvider = dataUseConsentProvider
        self.micGate = micGate
        self.bookSearch = bookSearch
        self.embedderPrewarm = embedderPrewarm
        self.chapterIndexResponderFactory = chapterIndexResponderFactory
        self.chapterIndexCoordinatorFactory = chapterIndexCoordinatorFactory
        self.chapterIndexContentVersionProvider = chapterIndexContentVersionProvider

        self.clientFactory = clientFactory ?? { RealtimeAPIAdapter() }
        self.keyFetcherFactory =
            keyFetcherFactory ?? {
                DisabledLegacyEphemeralKeyFetcher()
            }
        let effectiveSessionCoordinatorFactory: @MainActor () -> (any VoiceSessionCoordinating)? = sessionCoordinatorFactory ?? {
            Self.isTrialVoiceSessionFlowEnabled ? VoiceSessionAPIClient(workerClient: workerClient) : nil
        }
        self.sessionCoordinatorFactory = effectiveSessionCoordinatorFactory
        self.controlSocketFactory = controlSocketFactory ?? { rishiSessionId, onTerminal in
            guard Self.isTrialVoiceSessionFlowEnabled else { return nil }
            return ControlWebSocketClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                dataUseConsentProvider: dataUseConsentProvider,
                rishiSessionId: rishiSessionId,
                onTerminal: onTerminal
            )
        }
        self.sessionRegistry = sessionRegistry ?? VoiceSessionRegistry(
            currentUserIDProvider: userIdProvider,
            endServerSession: { id in
                guard let coordinator = effectiveSessionCoordinatorFactory() else { return }
                try await coordinator.endSession(rishiSessionId: id)
            }
        )
    }
    func getSession()->RealtimeVoiceSession? { self.session}

    func prewarmVoiceChat(for bookID: BookID, userID: UserID) {
        guard userIdProvider() == userID else { return }
        // The pinned WebRTC SDK constructs the local audio track when its
        // Conversation is initialized. Do not do that before permission is
        // granted; first-use startup prewarms after `request()` succeeds.
        guard micGate.currentDecision == .granted else { return }
        if let pendingPrewarm,
           pendingPrewarm.userID == userID,
           pendingPrewarm.bookID == bookID {
            return
        }
        cancelPrewarm()
        let client = clientFactory()
        let task = Task { await client.prewarm() }
        pendingPrewarm = PendingPrewarm(userID: userID, bookID: bookID, client: client, task: task)
    }

    func cancelPrewarm() {
        guard let pendingPrewarm else { return }
        self.pendingPrewarm = nil
        pendingPrewarm.task.cancel()
        Task { await pendingPrewarm.client.cancelPrewarm() }
    }

    var pendingReaderCleanupCount: Int { cleanupQueue.count }

    /// Registers reader-owned cleanup at voice-start time. Cleanup remains
    /// scoped to this identity so a stale reader cannot tear down a newer
    /// reader's session.
    func registerReaderCleanup(for identity: ReaderSessionIdentity) {
        cleanupQueue.register(identity)
    }

    /// Drains only reader sessions that explicitly registered for cleanup.
    /// Taking the items first makes repeated library activation harmless. The
    /// caller also waits for the registry's background end delivery so a new
    /// reader cannot race the worker's active-session check.
    @discardableResult
    func cleanupRegisteredReaderSessions() async -> Bool {
        if let readerCleanupTask {
            // The library path observer and the next openBook action can
            // arrive together. The first caller drains the queue, so later
            // callers must join its flight instead of treating the now-empty
            // queue as proof that cleanup is finished.
            return await readerCleanupTask.value
        }

        let identities = cleanupQueue.takeAll()
        // Do not put an account-wide network request on every normal book
        // open. The queue is the explicit ownership signal for reader voice
        // cleanup; an empty queue means this library transition has nothing
        // voice-related to tear down.
        guard !identities.isEmpty else { return true }

        readerCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return true }
            for identity in identities {
                await self.requestEnd(readerSessionIdentity: identity)
            }
            await self.sessionRegistry.waitForServerEnd()

            // The local session ID can be lost across a crash, or the original
            // POST /end can exhaust its delivery retries. At the library boundary
            // there must be no reader-owned server session left behind, so use the
            // account-scoped recovery RPC as a final sweep before another book can
            // be presented. Terminal rows are safe here: the Worker no longer
            // treats provider cleanup as admission state.
            guard let coordinator = self.sessionCoordinatorFactory() else { return true }
            for attempt in 1...Self.libraryCleanupMaxAttempts {
                do {
                    if let endedID = try await coordinator.endActiveSessionIfAny() {
                        self.noteRishiSessionId(endedID)
                    }
                    return true
                } catch {
                    if attempt == Self.libraryCleanupMaxAttempts {
                        Log.event("voice.presenter.library_cleanup.end_active.failed", level: .error, data: [
                            "attempts": String(attempt),
                            "error": String(describing: error),
                        ])
                    } else {
                        try? await Task.sleep(for: .milliseconds(Self.endDeliveryBackoffMs * attempt))
                    }
                }
            }
            return false
        }
        let result = await readerCleanupTask!.value
        readerCleanupTask = nil
        if !result {
            // Keep the ownership signal durable in memory. A background
            // cleanup failure must make the next voice start retry cleanup,
            // rather than silently creating against the still-live Worker
            // row.
            for identity in identities {
                cleanupQueue.register(identity)
            }
        }
        return result
    }

    /// Starts reader cleanup without making library navigation wait for the
    /// network. Voice start joins the task when it needs a server-safe
    /// boundary, so opening a book stays responsive without reintroducing the
    /// stale-session race.
    func scheduleRegisteredReaderCleanup() {
        guard readerCleanupTask == nil, cleanupQueue.hasPending(asideFrom: nil) else { return }
        Task { @MainActor [weak self] in
            _ = await self?.cleanupRegisteredReaderSessions()
        }
    }

    private func takePrewarm(for bookID: BookID?, userID: UserID?) -> PendingPrewarm? {
        guard let pendingPrewarm else { return nil }
        self.pendingPrewarm = nil
        guard let bookID, let userID,
              pendingPrewarm.bookID == bookID,
              pendingPrewarm.userID == userID else {
            pendingPrewarm.task.cancel()
            Task { await pendingPrewarm.client.cancelPrewarm() }
            return nil
        }
        return pendingPrewarm
    }

    func start(
        bookId: BookID?,
        language: String = "en",
        initialQuote: String? = nil,
        bookContext: BookContextSnapshot? = nil,
        currentPageProvider: CurrentPageContextProvider? = nil,
        readerSessionIdentity: ReaderSessionIdentity? = nil
    ) async -> VoiceStartOutcome {

        guard !isStarting else { return .alreadyStarting }
        guard !isPresenting else { return .alreadyLive }
        isStarting = true
        let startCancellationToken = UUID()
        self.startCancellationToken = startCancellationToken

        // A library transition starts cleanup in the background. Join it only
        // when voice is requested, preserving fast book navigation while
        // keeping the Worker admission check behind the cleanup barrier.
        let canResumeParkedSameReader = readerSessionIdentity != nil
            && currentReaderSessionIdentity == readerSessionIdentity
            && sessionRegistry.state == .parked
        if (!canResumeParkedSameReader && cleanupQueue.hasPending(asideFrom: nil))
            || readerCleanupTask != nil {
            guard await cleanupRegisteredReaderSessions() else {
                state.recordError("Reader voice cleanup failed")
                enterFailure(reason: .sessionEndFailed)
                return .rejected
            }
        }

        if let readerSessionIdentity {
            registerReaderCleanup(for: readerSessionIdentity)
        }
        self.currentReaderSessionIdentity = readerSessionIdentity
        defer {
            isStarting = false
            if self.startCancellationToken == startCancellationToken {
                self.startCancellationToken = nil
            }
        }
        let pendingPrewarm = takePrewarm(for: bookId, userID: userIdProvider())
        var handedPrewarmToSession = false
        defer {
            if !handedPrewarmToSession, let pendingPrewarm {
                pendingPrewarm.task.cancel()
                Task { await pendingPrewarm.client.cancelPrewarm() }
            }
        }
        let startupTrace = VoiceStartupTrace()
        startupTrace.mark("requested", data: [
            "hasBook": String(bookId != nil),
            "isParked": String(sessionRegistry.state == .parked),
        ])

        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            state.recordError("Data use consent required")
            enterFailure(reason: .dataUseConsentRequired)
            return .rejected
        }

        guard self.startCancellationToken == startCancellationToken,
              !Task.isCancelled else { return .rejected }

        if await resumeParkedSessionIfEligible(
            bookId: bookId,
            language: language,
            initialQuote: initialQuote,
            bookContext: bookContext,
            currentPageProvider: currentPageProvider,
            readerSessionIdentity: readerSessionIdentity
        ) {
            return .live
        }

        restoreStaleSessionIdFromPersistenceOrSession()

        if let id = await session?.rishiSessionId {
            noteRishiSessionId(id)
        }

        if session != nil, !isPresenting {
            await requestEnd()
        }

        // Do not put server-side cleanup on the pre-chrome critical path.
        // VoiceSessionRegistry.register() still serializes a pending local
        // end before the transport connects, and an actual
        // VOICE_SESSION_ALREADY_ACTIVE response runs the force-end/retry
        // recovery below after the loading chrome is already visible.
        guard !isPresenting else { return .alreadyLive }

        guard self.startCancellationToken == startCancellationToken,
              !Task.isCancelled else { return .rejected }
        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            enterFailure(reason: .unknown("Sign in required"))
            return .rejected
        }

        // Consent can be revoked during asynchronous startup work. Re-check
        // it before even touching the microphone.
        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            state.recordError("Data use consent required")
            enterFailure(reason: .dataUseConsentRequired)
            return .rejected
        }

        guard self.startCancellationToken == startCancellationToken,
              !Task.isCancelled else { return .rejected }

        // Resolve permission before claiming audio or constructing anything
        // that can mint a server session. The realtime SDK also checks this
        // during WebRTC connect, but doing it here keeps denial off the
        // network critical path and makes the presenter decision testable.
        guard await micGate.request() == .granted else {
            guard !Task.isCancelled else { return .rejected }
            state.recordError("Microphone permission denied")
            enterFailure(reason: .micDenied)
            return .rejected
        }
        guard self.startCancellationToken == startCancellationToken,
              !Task.isCancelled else { return .rejected }

        isPresenting = true

        failure = nil
        pendingFailure = nil
        currentBookId = bookId
        pendingInitialQuote = initialQuote
        let metadataContext = Self.metadataOnly(bookContext)
        currentBookContext = metadataContext
        currentLanguage = language
        self.currentPageProvider = currentPageProvider
        self.currentReaderSessionIdentity = readerSessionIdentity
        let sessionToken = UUID()
        activeSessionToken = sessionToken

        state.reset()
        await coordinator.registerPreemption(for: .voice) { [weak self, sessionToken] in
            await self?.requestEndIfActive(sessionToken: sessionToken)
        }

        guard activeSessionToken == sessionToken,
              isPresenting,
              !Task.isCancelled else {
            activeSessionToken = nil
            isPresenting = false
            return .rejected
        }

        // Claim app-level audio ownership before starting session setup. A
        // voice-specific result prevents AVAudioSession failure from reaching
        // the Worker/OpenAI critical path.
        guard await coordinator.requestVoiceActiveMode() else {
            activeSessionToken = nil
            state.recordError("Audio session setup failed")
            enterFailure(reason: .audioSession)
            return .rejected
        }
        startupTrace.mark("audio_mode_acquired")

        guard activeSessionToken == sessionToken,
              isPresenting,
              !Task.isCancelled else {
            await coordinator.releaseActiveMode(.voice)
            activeSessionToken = nil
            isPresenting = false
            return .rejected
        }

        let conversationTask = Task { @MainActor in
            try await conversationLookup.findOrCreate(userId: userId, bookId: bookId)
        }
        defer { conversationTask.cancel() }
        startupTrace.mark("conversation_lookup_started")

        guard !Task.isCancelled else {
            conversationTask.cancel()
            await coordinator.releaseActiveMode(.voice)
            activeSessionToken = nil
            isPresenting = false
            return .rejected
        }

        let adapter = pendingPrewarm?.client ?? clientFactory()
        handedPrewarmToSession = pendingPrewarm != nil
        // A session start can fail before RealtimeVoiceSession reaches its
        // normal disconnect path (for example, a consent change between the
        // presenter and session checks). Always clear any adapter-only
        // prewarm left behind by that attempt.
        defer {
            Task { await adapter.cancelPrewarm() }
        }
        let fetcher = keyFetcherFactory()

        guard !Task.isCancelled else {
            await coordinator.releaseActiveMode(.voice)
            activeSessionToken = nil
            isPresenting = false
            return .rejected
        }

        let chapterDependenciesProvider: (@Sendable (BookID) async -> (ChapterIndexCoordinator?, String?))? =
            chapterIndexCoordinatorFactory.map { coordinatorFactory in
                { @Sendable bookId in
                    let contentVersion = await self.chapterIndexContentVersionProvider?(bookId)
                    let coordinator: ChapterIndexCoordinator? = if let contentVersion {
                        await coordinatorFactory(bookId, contentVersion)
                    } else {
                        nil
                    }
                    return (coordinator, contentVersion)
                }
            }

        let responderFactory: RealtimeVoiceSession.BookContextResponderFactory?
        if let bookSearch {
            responderFactory = { @Sendable bookId in
                let dependenciesProvider: (@Sendable () async -> (ChapterIndexCoordinator?, String?))? =
                    chapterDependenciesProvider.map { provider in
                        { @Sendable in await provider(bookId) }
                    }
                return BookContextResponder(
                    client: adapter,
                    search: bookSearch,
                    bookId: bookId,
                    chapterIndexDependenciesProvider: dependenciesProvider
                )
            }
        } else if currentPageProvider != nil {
            responderFactory = { @Sendable bookId in
                let dependenciesProvider: (@Sendable () async -> (ChapterIndexCoordinator?, String?))? =
                    chapterDependenciesProvider.map { provider in
                        { @Sendable in await provider(bookId) }
                    }
                return BookContextResponder(
                    client: adapter,
                    bookId: bookId,
                    chapterIndexDependenciesProvider: dependenciesProvider
                )
            }
        } else {
            responderFactory = nil
        }

        let effectiveChapterIndexResponderFactory: RealtimeVoiceSession.ChapterIndexBookContextResponderFactory?
        if let injected = chapterIndexResponderFactory {
            effectiveChapterIndexResponderFactory = injected
        } else if let bookSearch {
            effectiveChapterIndexResponderFactory = { @Sendable bookId, coordinator, contentVersion in
                BookContextResponder(
                    client: adapter,
                    search: bookSearch,
                    bookId: bookId,
                    chapterIndexCoordinator: coordinator,
                    chapterIndexContentVersion: contentVersion
                )
            }
        } else if currentPageProvider != nil {
            effectiveChapterIndexResponderFactory = { @Sendable bookId, coordinator, contentVersion in
                BookContextResponder(
                    client: adapter,
                    bookId: bookId,
                    chapterIndexCoordinator: coordinator,
                    chapterIndexContentVersion: contentVersion
                )
            }
        } else {
            effectiveChapterIndexResponderFactory = nil
        }

        let session = RealtimeVoiceSession(
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: adapter,
            state: state,
            dataUseConsentProvider: dataUseConsentProvider,
            sessionCoordinator: sessionCoordinatorFactory(),
            controlSocketFactory: controlSocketFactory,
            onTerminalFailure: { [weak self] reason in
                await self?.handleTerminalFailure(reason, sessionToken: sessionToken)
            },
            responderFactory: responderFactory,
            chapterIndexResponderFactory: responderFactory == nil ? effectiveChapterIndexResponderFactory : nil,
            chapterIndexCoordinatorFactory: chapterIndexCoordinatorFactory,
            chapterIndexContentVersionProvider: chapterIndexContentVersionProvider,
            currentPageProvider: currentPageProvider,
            readerSessionIdentity: readerSessionIdentity,
            embedderPrewarm: embedderPrewarm
        )

        guard activeSessionToken == sessionToken, isPresenting else {
            conversationTask.cancel()
            await session.end()
            return .rejected
        }
        self.session = session
        await sessionRegistry.register(session)
        startupTrace.mark("transport_object_registered")

        guard activeSessionToken == sessionToken, isPresenting else {
            conversationTask.cancel()
            await closeAbandonedSession(session)
            return .rejected
        }

        // Install the single transcript stream continuation before connecting.
        // The lookup below can be slow, but the realtime event pump must not
        // start without a continuation or early transcript events are dropped.
        let transcriptStream = adapter.transcriptStream()

        let startResult = await session.start(
            language: language,
            bookId: bookId,
            currentPage: metadataContext?.currentPage,
            pageText: nil,
            outline: metadataContext?.outline,
            activeParagraphText: nil,
            preflighted: true,
            prewarmed: pendingPrewarm != nil
        )

        guard activeSessionToken == sessionToken,
              isPresenting,
              !Task.isCancelled else {
            await closeAbandonedSession(session)
            return .rejected
        }

        switch startResult {
        case .live:
            break
        case let .failed(reason):
            await closeAbandonedSession(session)
            enterFailure(reason: reason)
            return .rejected
        case .cancelled:
            await closeAbandonedSession(session)
            return .rejected
        }

        guard activeSessionToken == sessionToken, isPresenting else {
            await closeAbandonedSession(session)
            return .rejected
        }
        startupTrace.mark("transport_start_returned", data: [
            "status": String(describing: state.status),
        ])

        let conversation: Conversation
        do {
            // Session setup and conversation lookup run concurrently. This
            // keeps the WebRTC handshake on the critical path, not the local
            // conversation-store scan/upsert.
            conversation = try await conversationTask.value
            startupTrace.mark("conversation_ready")
            guard !Task.isCancelled else {
                await closeAbandonedSession(session)
                return .rejected
            }
        } catch {
            startupTrace.mark("conversation_lookup_failed")
            await sessionRegistry.close()
            if let currentSession = self.session, currentSession === session {
                self.session = nil
                bridgeTask?.cancel()
                bridgeTask = nil
            }
            guard !Task.isCancelled,
                  activeSessionToken == sessionToken,
                  isPresenting,
                  self.session === session else { return .rejected }
            Log.event(
                "voice.presenter.lookup.failed",
                level: .error,
                data: [
                    "error": String(describing: error)
                ]
            )
            state.recordError(String(describing: error))
            enterFailure(reason: .unknown(String(describing: error)))
            return .rejected
        }

        // End/cancel may have closed this session while lookup was pending.
        // Do not attach a transcript bridge to a newer or already-ended
        // session.
        guard let currentSession = self.session,
              currentSession === session,
              isPresenting else { return .rejected }

        if case .failed = state.status {
            // Keep the existing failure/retry handling below. A failed
            // transport does not need a transcript bridge.
        } else {
            // transcriptStream() is single-consumer — ping activity from the
            // bridge (sole consumer) rather than a parallel stream reader.
            let bridge = VoiceTranscriptBridge(
                messageStore: messageStore,
                dirtyHook: dirtyHook,
                onActivity: {
                    await session.notifyVoiceActivity()
                }
            )

            let conversationId = conversation.id
            let presenterState = state
            bridgeTask?.cancel()

            bridgeTask = Task {
                await bridge.consume(
                    stream: transcriptStream,
                    conversationId: conversationId,
                    state: presenterState
                )
            }
        }
        startupTrace.mark("startup_ready", data: [
            "status": String(describing: state.status),
        ])

        var createAttempt = 1
        while case .failed(.sessionStart(.alreadyActive)) = state.status,
              createAttempt < Self.alreadyActiveCreateMaxAttempts {
            guard !Task.isCancelled else {
                await closeAbandonedSession(session)
                return .rejected
            }
            createAttempt += 1
            Log.event("voice.presenter.create.retry", level: .info, data: [
                "attempt": String(createAttempt),
            ])
            await resolveServerAlreadyActiveConflict()
            guard !Task.isCancelled else {
                await closeAbandonedSession(session)
                return .rejected
            }
            state.reset()
            let metadataContext = Self.metadataOnly(bookContext)
            let retryResult = await session.start(
                language: language,
                bookId: bookId,
                currentPage: metadataContext?.currentPage,
                pageText: nil,
                outline: metadataContext?.outline,
                activeParagraphText: nil,
                prewarmed: false
            )
            switch retryResult {
            case .cancelled:
                await closeAbandonedSession(session)
                return .rejected
            case .live, .failed:
                // A failed retry leaves the session state populated with its
                // specific failure; the common failure handling below owns
                // the alert and persisted server-session cleanup.
                break
            }
        }

        if case .failed = state.status {
            // Keep persisted ledger id for a follow-up end + retry.
        } else {
            clearPersistedServerSessionId()
        }

        if let id = await session.rishiSessionId {
            noteRishiSessionId(id)
            sessionRegistry.recordServerSessionID(id)
        }

        if case .failed(let reason) = state.status {
            if let id = await session.rishiSessionId {
                noteRishiSessionId(id)
            }
            enterFailure(reason: reason)
            return .rejected
        }

        guard !Task.isCancelled,
              activeSessionToken == sessionToken,
              isPresenting,
              state.status == .live else {
            await closeAbandonedSession(session)
            return .rejected
        }
        return .live
    }

    /// Park the live session when the user dismisses voice chrome so a quick
    /// reopen reuses WebRTC + the ledger row instead of create/end races.
    func dismissVoiceChrome() async {
        await parkSession()
    }

    /// Hides the reader chrome while keeping the live session object (WebRTC,
    /// control socket, ledger row) for a short grace period so a quick return
    /// does not pay reconnect / create-session costs.
    func parkSession() async {
        guard session != nil || isPresenting else { return }
        isPresenting = false
        await sessionRegistry.park()
    }

    private func resumeParkedSessionIfEligible(
        bookId: BookID?,
        language: String,
        initialQuote: String?,
        bookContext: BookContextSnapshot?,
        currentPageProvider: CurrentPageContextProvider?,
        readerSessionIdentity: ReaderSessionIdentity?
    ) async -> Bool {
        guard let session, !isPresenting else { return false }
        guard sessionRegistry.state == .parked else { return false }
        guard session.readerSessionIdentity == readerSessionIdentity else { return false }
        if case .failed = state.status { return false }
        if case .ended = state.status { return false }

        isPresenting = true
        failure = nil
        pendingFailure = nil
        currentBookId = bookId
        pendingInitialQuote = initialQuote
        let metadataContext = Self.metadataOnly(bookContext)
        currentBookContext = metadataContext
        currentLanguage = language
        self.currentPageProvider = currentPageProvider
        self.currentReaderSessionIdentity = readerSessionIdentity

        state.reset()
        await session.updateReaderContext(language: language, bookContext: metadataContext)
        await sessionRegistry.resume()
        return isPresenting
            && self.session === session
            && sessionRegistry.state == .live
    }

    private static func metadataOnly(_ context: BookContextSnapshot?) -> BookContextSnapshot? {
        guard let context else { return nil }
        return BookContextSnapshot(
            bookId: context.bookId,
            currentPage: context.currentPage,
            pageText: nil,
            outline: context.outline,
            activeParagraphText: nil
        )
    }

    /// Optimistic End: dismiss the cover immediately, tear down local
    /// WebRTC/control/audio without awaiting hangup, then retry
    /// `POST …/end` in the background. Single-flight across End button,
    /// cover swipe, and audio preemption. Does **not** gate delivery on
    /// `isPresenting` (optimistic dismiss clears it first).
    private func requestEndIfActive(sessionToken: UUID) async {
        guard activeSessionToken == sessionToken else { return }
        await requestEnd()
    }

    func requestEnd(readerSessionIdentity: ReaderSessionIdentity? = nil) async {
        if let readerSessionIdentity {
            guard currentReaderSessionIdentity == readerSessionIdentity else { return }
        }
        cancelPrewarm()
        // Nothing left to tear down (and not mid-present) — ignore double tap.
        guard session != nil || isPresenting || startCancellationToken != nil else { return }
        if let endFlightTask {
            // Reader disappearance and the library boundary can arrive at the
            // same time. Join the existing flight instead of returning before
            // it has reached the registry/server cleanup.
            await endFlightTask.value
            return
        }
        isRequestingEnd = true

        endFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Dismiss first — before local teardown / delivery.
            self.isPresenting = false
            self.activeSessionToken = nil
            self.startCancellationToken = nil

            await self.sessionRegistry.close()

            self.bridgeTask?.cancel()
            self.bridgeTask = nil
            self.session = nil
            self.currentBookId = nil
            self.pendingInitialQuote = nil
            self.currentBookContext = nil
            self.currentLanguage = "en"
            self.currentPageProvider = nil
            self.currentReaderSessionIdentity = nil

            // Release the End flight before background delivery. The registry
            // owns serialization of that delivery when the replacement
            // transport registers.
            self.isRequestingEnd = false
        }
        await endFlightTask?.value
        endFlightTask = nil
    }

    /// Compatibility alias — all End entry points use ``requestEnd``.
    func end() async {
        await requestEnd()
    }

    /// Retries ledger hangup a few times with short backoff. Success includes
    /// HTTP ok and already-terminal / `NO_ACTIVE_VOICE_SESSION` (handled inside
    /// `VoiceSessionAPIClient.endSession`). On exhaustion, surfaces an
    /// acknowledge-only alert — never `retry()` / start — and never dismisses
    /// a newer live cover.
    private func deliverEnd(
        rishiSessionId: String,
        using coordinator: any VoiceSessionCoordinating
    ) async {
        let cleared = await deliverEndWithRetries(
            rishiSessionId: rishiSessionId,
            using: coordinator
        )
        if cleared {
            // Keep staleRishiSessionId until a new session create succeeds so
            // a quick reopen can re-end if the server lock is still clearing.
            recentlyDeliveredEndSessionId = rishiSessionId
            return
        }

        if isPresenting {
            // A newer session is already up — do not clobber it with end-failure UI.
            Log.event("voice.presenter.end_delivery.exhausted_while_live", level: .warning, data: [
                "rishiSessionId": rishiSessionId,
            ])
            return
        }
        enterFailure(reason: .sessionEndFailed)
    }

    /// Cleans up a locally known stale ledger row during explicit recovery.
    /// Blocks until hangup succeeds or retries are exhausted — preventing an
    /// immediate `VOICE_SESSION_ALREADY_ACTIVE` on Try again.
    private func endStaleServerSessionIfNeeded() async {
        restoreStaleSessionIdFromPersistenceOrSession()
        // A clean start has no reason to make a network request just to ask
        // the server whether an active session exists. Besides adding a
        // round-trip to every voice open, a stalled end-active request used
        // URLSession's long default timeout and could keep the chrome hidden
        // for a minute. If create later reports VOICE_SESSION_ALREADY_ACTIVE,
        // resolveServerAlreadyActiveConflict() performs the force-end path.
        guard let rishiSessionId = staleRishiSessionId else {
            Log.event("voice.presenter.end_active.skipped", level: .debug, data: [
                "reason": "no_local_stale_session",
            ])
            return
        }
        if recentlyDeliveredEndSessionId == rishiSessionId {
            try? await Task.sleep(for: .milliseconds(Self.serverSettleAfterEndMs))
            return
        }
        guard let coordinator = sessionCoordinatorFactory() else { return }
        let cleared = await deliverEndWithRetries(
            rishiSessionId: rishiSessionId,
            using: coordinator
        )
        if cleared {
            recentlyDeliveredEndSessionId = rishiSessionId
            try? await Task.sleep(for: .milliseconds(Self.serverSettleAfterEndMs))
        }
    }

    /// Re-POST end for the persisted ledger id, then wait for server settle.
    private func resolveServerAlreadyActiveConflict() async {
        if let coordinator = sessionCoordinatorFactory() {
            do {
                if let endedId = try await coordinator.endActiveSessionIfAny() {
                    noteRishiSessionId(endedId)
                }
            } catch {
                Log.event("voice.presenter.end_active.failed", level: .warning, data: [
                    "error": String(describing: error),
                ])
            }
            try? await Task.sleep(for: .milliseconds(Self.serverSettleAfterEndMs))
        }

        restoreStaleSessionIdFromPersistenceOrSession()
        guard let rishiSessionId = staleRishiSessionId,
              let coordinator = sessionCoordinatorFactory() else {
            try? await Task.sleep(for: .milliseconds(Self.alreadyActiveRetryBackoffMs))
            return
        }
        _ = await deliverEndWithRetries(
            rishiSessionId: rishiSessionId,
            using: coordinator
        )
        try? await Task.sleep(for: .milliseconds(Self.serverSettleAfterEndMs))
    }

    private func restoreStaleSessionIdFromPersistenceOrSession() {
        guard let currentUserID = userIdProvider() else {
            staleRishiSessionId = nil
            staleRishiSessionUserID = nil
            recentlyDeliveredEndSessionId = nil
            return
        }
        if staleRishiSessionUserID != currentUserID {
            staleRishiSessionId = nil
            recentlyDeliveredEndSessionId = nil
            staleRishiSessionUserID = currentUserID
        }
        if staleRishiSessionId == nil {
            staleRishiSessionId = sessionRegistry.persistedServerSessionID
        }
    }

    private func noteRishiSessionId(_ id: String) {
        guard let currentUserID = userIdProvider() else { return }
        staleRishiSessionId = id
        staleRishiSessionUserID = currentUserID
        sessionRegistry.recordServerSessionID(id)
    }

    private func clearPersistedServerSessionId() {
        staleRishiSessionId = nil
        staleRishiSessionUserID = nil
        recentlyDeliveredEndSessionId = nil
        sessionRegistry.persistedServerSessionID = nil
        if let session {
            Task { await session.acknowledgeServerEnd() }
        }
    }

    @discardableResult
    private func deliverEndWithRetries(
        rishiSessionId: String,
        using coordinator: any VoiceSessionCoordinating
    ) async -> Bool {
        for attempt in 1...Self.endDeliveryMaxAttempts {
            do {
                try await coordinator.endSession(rishiSessionId: rishiSessionId)
                Log.event("voice.presenter.end_delivery.succeeded", level: .info, data: [
                    "rishiSessionId": rishiSessionId,
                ])
                return true
            } catch {
                if VoiceSessionAPIClient.isAlreadyTerminalEndError(error) {
                    return true
                }
                Log.event("voice.presenter.end_delivery.failed", level: .warning, data: [
                    "rishiSessionId": rishiSessionId,
                    "attempt": String(attempt),
                    "error": String(describing: error),
                ])
                if attempt < Self.endDeliveryMaxAttempts {
                    let delayMs = Self.endDeliveryBackoffMs * attempt
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }
        return false
    }

    private func closeAbandonedSession(_ session: RealtimeVoiceSession) async {
        guard let id = await session.end() else { return }
        noteRishiSessionId(id)
        if sessionRegistry.state != .closing {
            await sessionRegistry.close()
        } else if let coordinator = sessionCoordinatorFactory() {
            _ = await deliverEndWithRetries(rishiSessionId: id, using: coordinator)
        }
    }

    func retry() async {
        if let id = await session?.rishiSessionId {
            noteRishiSessionId(id)
        }
        let bookId = currentBookId
        let quote = pendingInitialQuote
        let context = currentBookContext
        let language = currentLanguage
        let pageProvider = currentPageProvider
        let readerIdentity = currentReaderSessionIdentity
        clearFailure()
        await endStaleServerSessionIfNeeded()
        await start(
            bookId: bookId,
            language: language,
            initialQuote: quote,
            bookContext: context,
            currentPageProvider: pageProvider,
            readerSessionIdentity: readerIdentity
        )
    }

    /// Dismiss the consent-specific alert without discarding the failed
    /// feature's book, quote, or context. `retry()` consumes that context
    /// after the user grants consent; declining consent can call
    /// `clearFailure()` to discard it.
    func prepareForDataUseConsent() {
        failure = nil
        pendingFailure = nil
    }
    

    func clearFailure() {
        let sessionToCapture = session
        restoreStaleSessionIdFromPersistenceOrSession()
        if let sessionToCapture {
            Task { @MainActor in
                if let id = await sessionToCapture.rishiSessionId {
                    noteRishiSessionId(id)
                }
            }
        }
        failure = nil
        pendingFailure = nil
        activeSessionToken = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        session = nil
        isPresenting = false
        isRequestingEnd = false
        currentBookId = nil
        pendingInitialQuote = nil
        currentBookContext = nil
        currentLanguage = "en"
        state.reset()
    }

    func enterFailure(reason: VoiceSessionFailureReason) {
        let sessionToCapture = session
        restoreStaleSessionIdFromPersistenceOrSession()
        if let sessionToCapture {
            Task { @MainActor in
                if let id = await sessionToCapture.rishiSessionId {
                    noteRishiSessionId(id)
                }
            }
        }
        guard failure == nil, pendingFailure == nil else { return }
        state.apply(status: .failed(reason: reason))
        let message: String? = if case .dataUseConsentRequired = reason {
            nil
        } else {
            state.lastError
        }
        let alert = VoiceFailureAlert(reason: reason, message: message)
        if isPresenting {

            pendingFailure = alert
            isPresenting = false
        } else {

            failure = alert
        }
    }

    private func handleTerminalFailure(
        _ reason: VoiceSessionFailureReason,
        sessionToken: UUID
    ) async {
        guard activeSessionToken == sessionToken else { return }
        enterFailure(reason: reason)
        await sessionRegistry.close()
    }

    func promotePendingFailure() {
        guard let pending = pendingFailure else { return }
        pendingFailure = nil
        failure = pending
    }
}

private actor DisabledLegacyEphemeralKeyFetcher: EphemeralKeyFetching {
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        throw RishiError.network(
            code: "legacy_voice_disabled",
            message: "The legacy realtime voice flow is disabled"
        )
    }
}
