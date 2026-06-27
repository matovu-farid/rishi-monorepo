import Foundation
import Observation
import RishiAPI
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

    private var bridgeTask: Task<Void, Never>?

    init(
        coordinator: AudioSessionCoordinator,
        workerClient: WorkerClient,
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate(),
        bookSearch: (any BookSearch)? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        clientFactory: (@MainActor () -> any RealtimeClientAPI)? = nil,
        keyFetcherFactory: (@MainActor () -> any EphemeralKeyFetching)? = nil
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
    }

    func start(
        bookId: BookID?,
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

        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            enterFailure(reason: .unknown("Sign in required"))
            return
        }

        state.reset()

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
        let bridge = VoiceTranscriptBridge(
            messageStore: messageStore,
            dirtyHook: dirtyHook
        )

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
            responderFactory: responderFactory,
            embedderPrewarm: embedderPrewarm
        )
        self.session = session

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
            language: "en",
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
    }

    func retry() async {
        let bookId = currentBookId
        let quote = pendingInitialQuote
        let context = currentBookContext
        clearFailure()
        await start(bookId: bookId, initialQuote: quote, bookContext: context)
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
