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

@MainActor
@Observable
final class VoiceSessionPresenter {

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

    private let coordinator: AudioSessionCoordinator
    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let conversationLookup: ConversationLookup
    private let userIdProvider: @MainActor () -> UserID?
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider

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

    /// Background `POST …/end` retries after optimistic dismiss. Not cancelled
    /// on a subsequent `start` — delivery for the prior session id still matters.
    private var endDeliveryTask: Task<Void, Never>?

    /// Session id whose background end delivery completed successfully. Keep
    /// the persisted id until the next create succeeds, but do not send a
    /// second concurrent end for the same id during that start.
    private var recentlyDeliveredEndSessionId: String?

    /// Prevents repeated taps/lifecycle callbacks from creating overlapping
    /// server sessions while the first start is suspended on network work.
    private var isStarting = false

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
    /// Retries when POST /voice-sessions returns VOICE_SESSION_ALREADY_ACTIVE.
    private static let alreadyActiveCreateMaxAttempts = 3
    private static let alreadyActiveRetryBackoffMs = 600

    /// Ledger row id that still needs `POST …/end` before a new session can
    /// be created. Survives `clearFailure()` so Try again can unblock the server.
    private var staleRishiSessionId: String?

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
            endServerSession: { id in
                guard let coordinator = effectiveSessionCoordinatorFactory() else { return }
                try await coordinator.endSession(rishiSessionId: id)
            }
        )
    }
    func getSession()->RealtimeVoiceSession? { self.session}

    func start(
        bookId: BookID?,
        language: String = "en",
        initialQuote: String? = nil,
        bookContext: BookContextSnapshot? = nil,
        currentPageProvider: CurrentPageContextProvider? = nil,
        readerSessionIdentity: ReaderSessionIdentity? = nil
    ) async {

        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let startupTrace = VoiceStartupTrace()
        startupTrace.mark("requested", data: [
            "hasBook": String(bookId != nil),
            "isParked": String(sessionRegistry.state == .parked),
        ])

        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            state.recordError("Data use consent required")
            enterFailure(reason: .dataUseConsentRequired)
            return
        }

        if await resumeParkedSessionIfEligible(
            bookId: bookId,
            language: language,
            initialQuote: initialQuote,
            bookContext: bookContext,
            currentPageProvider: currentPageProvider,
            readerSessionIdentity: readerSessionIdentity
        ) {
            return
        }

        restoreStaleSessionIdFromPersistenceOrSession()

        if let id = await session?.rishiSessionId {
            noteRishiSessionId(id)
        }

        if session != nil, !isPresenting {
            await requestEnd()
        }

        await awaitPendingEndDelivery()
        await endStaleServerSessionIfNeeded()

        guard !isPresenting else { return }
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

        // Consent can be revoked while stale-session cleanup and other
        // asynchronous startup work is in flight. Re-check immediately before
        // touching the microphone or creating a new remote voice session.
        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            state.recordError("Data use consent required")
            enterFailure(reason: .dataUseConsentRequired)
            return
        }

        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            enterFailure(reason: .unknown("Sign in required"))
            return
        }

        state.reset()
        await coordinator.registerPreemption(for: .voice) { [weak self] in
            await self?.requestEnd()
        }

        // The realtime SDK requests microphone permission inside connect().
        // Claim app-level audio ownership before starting session setup.
        await coordinator.requestActiveMode(.voice)
        startupTrace.mark("audio_mode_acquired")

        async let conversationTask = conversationLookup.findOrCreate(
            userId: userId,
            bookId: bookId
        )
        startupTrace.mark("conversation_lookup_started")

        let adapter = clientFactory()
        let fetcher = keyFetcherFactory()

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
            await session.end()
            return
        }
        self.session = session
        await sessionRegistry.register(session)
        startupTrace.mark("transport_object_registered")

        guard activeSessionToken == sessionToken, isPresenting else {
            await closeAbandonedSession(session)
            return
        }

        // Install the single transcript stream continuation before connecting.
        // The lookup below can be slow, but the realtime event pump must not
        // start without a continuation or early transcript events are dropped.
        let transcriptStream = adapter.transcriptStream()

        await session.start(
            language: language,
            bookId: bookId,
            currentPage: metadataContext?.currentPage,
            pageText: nil,
            outline: metadataContext?.outline,
            activeParagraphText: nil,
            preflighted: true
        )

        guard activeSessionToken == sessionToken, isPresenting else {
            await closeAbandonedSession(session)
            return
        }
        startupTrace.mark("transport_start_returned", data: [
            "status": String(describing: state.status),
        ])

        let conversation: Conversation
        do {
            // Session setup and conversation lookup run concurrently. This
            // keeps the WebRTC handshake on the critical path, not the local
            // conversation-store scan/upsert.
            conversation = try await conversationTask
            startupTrace.mark("conversation_ready")
        } catch {
            startupTrace.mark("conversation_lookup_failed")
            await sessionRegistry.close()
            if let currentSession = self.session, currentSession === session {
                self.session = nil
                bridgeTask?.cancel()
                bridgeTask = nil
            }
            guard !Task.isCancelled else { return }
            Log.event(
                "voice.presenter.lookup.failed",
                level: .error,
                data: [
                    "error": String(describing: error)
                ]
            )
            state.recordError(String(describing: error))
            enterFailure(reason: .unknown(String(describing: error)))
            return
        }

        // End/cancel may have closed this session while lookup was pending.
        // Do not attach a transcript bridge to a newer or already-ended
        // session.
        guard let currentSession = self.session,
              currentSession === session,
              isPresenting else { return }

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
            createAttempt += 1
            Log.event("voice.presenter.create.retry", level: .info, data: [
                "attempt": String(createAttempt),
            ])
            await resolveServerAlreadyActiveConflict()
            state.reset()
            let metadataContext = Self.metadataOnly(bookContext)
            await session.start(
                language: language,
                bookId: bookId,
                currentPage: metadataContext?.currentPage,
                pageText: nil,
                outline: metadataContext?.outline,
                activeParagraphText: nil
            )
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
        }
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
        return true
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
    func requestEnd() async {
        // Nothing left to tear down (and not mid-present) — ignore double tap.
        guard session != nil || isPresenting else { return }
        guard !isRequestingEnd else { return }
        isRequestingEnd = true

        // Dismiss first — before local teardown / delivery.
        isPresenting = false
        activeSessionToken = nil

        await sessionRegistry.close()

        bridgeTask?.cancel()
        bridgeTask = nil
        session = nil
        currentBookId = nil
        pendingInitialQuote = nil
        currentBookContext = nil
        currentLanguage = "en"
        currentPageProvider = nil
        currentReaderSessionIdentity = nil

        // Release the End flight before background delivery so a new session
        // can start and End without waiting on hangup retries.
        isRequestingEnd = false
        endDeliveryTask = Task { [weak self] in
            await self?.sessionRegistry.waitForServerEnd()
        }
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

    /// Ends a stale ledger row before starting a new session. Blocks until
    /// hangup succeeds or retries are exhausted — prevents immediate
    /// `VOICE_SESSION_ALREADY_ACTIVE` on Try again.
    private func endStaleServerSessionIfNeeded() async {
        if let coordinator = sessionCoordinatorFactory() {
            do {
                if let endedId = try await coordinator.endActiveSessionIfAny() {
                    noteRishiSessionId(endedId)
                    try? await Task.sleep(for: .milliseconds(Self.serverSettleAfterEndMs))
                }
            } catch {
                Log.event("voice.presenter.end_active.failed", level: .warning, data: [
                    "error": String(describing: error),
                ])
            }
        }

        restoreStaleSessionIdFromPersistenceOrSession()
        guard let rishiSessionId = staleRishiSessionId else { return }
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

    /// An optimistic End owns the only delivery attempt for its session. A
    /// subsequent Start must wait for that attempt before running stale-session
    /// cleanup or creating a new ledger row; otherwise both paths POST /end
    /// concurrently and create can observe VOICE_SESSION_ALREADY_ACTIVE.
    private func awaitPendingEndDelivery() async {
        guard let task = endDeliveryTask else { return }
        await task.value
        endDeliveryTask = nil
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
        if staleRishiSessionId == nil {
            staleRishiSessionId = sessionRegistry.persistedServerSessionID
        }
    }

    private func noteRishiSessionId(_ id: String) {
        staleRishiSessionId = id
        sessionRegistry.recordServerSessionID(id)
    }

    private func clearPersistedServerSessionId() {
        staleRishiSessionId = nil
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
