import Foundation
import Observation
import RishiCore
import RishiAudio
import RishiChat
import RishiCore
import RishiLogging
import RishiSearch
import RishiVoice

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

    private let coordinator: AudioSessionCoordinator
    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let conversationLookup: ConversationLookup
    private let userIdProvider: @MainActor () -> UserID?
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let micGate: any MicPermissionGate

    private let bookSearch: (any BookSearch)?
    private let embedderPrewarm: (@Sendable () async -> Void)?

    private let clientFactory: @MainActor () -> any RealtimeClientAPI
    private let keyFetcherFactory: @MainActor () -> any EphemeralKeyFetching
    private let sessionCoordinatorFactory: @MainActor () -> (any VoiceSessionCoordinating)?
    private let controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)

    private var bridgeTask: Task<Void, Never>?

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
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate(),
        bookSearch: (any BookSearch)? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        clientFactory: (@MainActor () -> any RealtimeClientAPI)? = nil,
        keyFetcherFactory: (@MainActor () -> any EphemeralKeyFetching)? = nil,
        sessionCoordinatorFactory: (@MainActor () -> (any VoiceSessionCoordinating)?)? = nil,
        controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)? = nil
    ) {
        self.state = VoiceSessionState()
        self.coordinator = coordinator
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.userIdProvider = userIdProvider
        self.dirtyHook = dirtyHook
        self.micGate = micGate
        self.bookSearch = bookSearch
        self.embedderPrewarm = embedderPrewarm

        self.clientFactory = clientFactory ?? { RealtimeAPIAdapter() }
        self.keyFetcherFactory =
            keyFetcherFactory ?? {
                EphemeralKeyFetcher(workerClient: workerClient)
            }
        self.sessionCoordinatorFactory = sessionCoordinatorFactory ?? {
            Self.isTrialVoiceSessionFlowEnabled ? VoiceSessionAPIClient(workerClient: workerClient) : nil
        }
        self.controlSocketFactory = controlSocketFactory ?? { rishiSessionId, onTerminal in
            guard Self.isTrialVoiceSessionFlowEnabled else { return nil }
            return ControlWebSocketClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                rishiSessionId: rishiSessionId,
                onTerminal: onTerminal
            )
        }
    }
    func getSession()->RealtimeVoiceSession? { self.session}

    func start(
        bookId: BookID?,
        language: String = "en",
        initialQuote: String? = nil,
        bookContext: BookContextSnapshot? = nil
    ) async {

        guard !isPresenting else { return }
        isPresenting = true

        failure = nil
        pendingFailure = nil
        currentBookId = bookId
        pendingInitialQuote = initialQuote
        currentBookContext = bookContext
        currentLanguage = language

        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            enterFailure(reason: .unknown("Sign in required"))
            return
        }

        state.reset()
        await coordinator.registerPreemption(for: .voice) { [weak self] in
            await self?.end()
        }
        // Acquire audio session BEFORE fetching the key. If the key fetch
        // fails we already own the session and must release it cleanly.
        await coordinator.requestActiveMode(.voice)

        let conversation: Conversation
        do {
            conversation = try await conversationLookup.findOrCreate(
                userId: userId,
                bookId: bookId
            )
        } catch {
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

        let adapter = clientFactory()
        let fetcher = keyFetcherFactory()

        let responderFactory:
            RealtimeVoiceSession.BookContextResponderFactory? = bookSearch.map {
                search in
                return { @Sendable bookId in
                    BookContextResponder(
                        client: adapter,
                        search: search,
                        bookId: bookId
                    )
                }
            }

        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: adapter,
            state: state,
            sessionCoordinator: sessionCoordinatorFactory(),
            controlSocketFactory: controlSocketFactory,
            responderFactory: responderFactory,
            embedderPrewarm: embedderPrewarm
        )
        self.session = session

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
                stream: adapter.transcriptStream(),
                conversationId: conversationId,
                state: presenterState
            )
        }

        await session.start(
            language: language,
            bookId: bookId,
            currentPage: bookContext?.currentPage,
            pageText: bookContext?.pageText,
            outline: bookContext?.outline,
            activeParagraphText: bookContext?.activeParagraphText
        )

        if case .failed(let reason) = state.status {
            enterFailure(reason: reason)
        }
    }

    func end() async {
        guard isPresenting else { return }
        await session?.end()
        bridgeTask?.cancel()
        bridgeTask = nil
        session = nil
        isPresenting = false
        currentBookId = nil
        pendingInitialQuote = nil
        currentBookContext = nil
        currentLanguage = "en"
    }

    func retry() async {
        let bookId = currentBookId
        let quote = pendingInitialQuote
        let context = currentBookContext
        let language = currentLanguage
        clearFailure()
        await start(bookId: bookId, language: language, initialQuote: quote, bookContext: context)
    }
    

    func clearFailure() {
        failure = nil
        pendingFailure = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        session = nil
        isPresenting = false
        currentBookId = nil
        pendingInitialQuote = nil
        currentBookContext = nil
        currentLanguage = "en"
        state.reset()
    }

    func enterFailure(reason: VoiceSessionFailureReason) {
        guard failure == nil, pendingFailure == nil else { return }
        state.apply(status: .failed(reason: reason))
        let alert = VoiceFailureAlert(reason: reason, message: state.lastError)
        if isPresenting {

            pendingFailure = alert
            isPresenting = false
        } else {

            failure = alert
        }
    }

    func promotePendingFailure() {
        guard let pending = pendingFailure else { return }
        pendingFailure = nil
        failure = pending
    }
}
