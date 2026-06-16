//
//  VoiceSessionPresenter.swift
//  rishi
//
//  Phase 10 Plan 10-06 — app-layer presenter binding the reader's voice
//  entry to the `RealtimeVoiceSession` actor and the SwiftUI
//  `.fullScreenCover` lifecycle. One instance is held by `AppDependencies`
//  for the app lifetime; `SignedInView` reads `isPresenting` to mount
//  `VoiceSessionHost`, and `ReaderVoiceEntry` calls `start(bookId:)` / `end()`.
//
//  Architecture:
//  - Owns a single shared `VoiceSessionState` (the @MainActor @Observable
//    surface SwiftUI binds to).
//  - Constructs a fresh `RealtimeAPIAdapter` + `RealtimeVoiceSession` PER
//    session because the underlying swift-realtime-openai `Conversation`
//    type is not reusable after disconnect.
//  - Drives `VoiceTranscriptBridge.consume(stream:conversationId:state:)`
//    in a background `Task` for the duration of each session so finalized
//    transcript fragments persist as `Message` rows.
//  - Releases the audio session (`.voice` mode on `AudioSessionCoordinator`)
//    transitively through `RealtimeVoiceSession.end()`.
//

import Foundation
import Observation
import RishiCore
import RishiAudio
import RishiAPI
import RishiChat
import RishiSearch
import RishiVoice
import RishiLogging

/// App-layer presenter binding the reader's voice entry to the
/// `RealtimeVoiceSession` actor.
@MainActor
@Observable
final class VoiceSessionPresenter {

    /// Observable state pushed by `RealtimeVoiceSession`. SwiftUI binds via
    /// `@Bindable` on the host view.
    let state: VoiceSessionState

    /// Drives the `.fullScreenCover(isPresented:)` binding on `SignedInView`
    /// that mounts `VoiceSessionHost`.
    /// Flipped to `true` by `start(bookId:)` once a conversation is resolved;
    /// flipped to `false` by `end()` or `dismissFailure()`.
    private(set) var isPresenting: Bool = false

    /// The in-flight session, if any. `nil` outside of a presenting window.
    private(set) var session: RealtimeVoiceSession?

    /// The book context the current presentation is bound to. Set at the top
    /// of `start`, cleared by `end()` / `dismissFailure()`. The
    /// `VoiceSessionHost` reads this to resolve the text-chat conversation
    /// when the user opens the in-voice text sheet.
    private(set) var currentBookId: BookID?

    /// The quote forwarded from the reader's "Ask about this" affordance, if
    /// any. Set at the top of `start`, cleared by `end()` / `dismissFailure()`.
    /// Non-nil means the host should auto-open the text-chat sheet prefilled
    /// with this quote.
    private(set) var pendingInitialQuote: String?

    /// The reader's book-context snapshot (title/author/page/active paragraph)
    /// the current presentation was started with, if any. Set at the top of
    /// `start`, cleared by `end()` / `dismissFailure()`. Retained so `retry()`
    /// can restart a failed session with the SAME context instead of a
    /// degraded bookId-only session.
    private(set) var currentBookContext: BookContextSnapshot?

    // MARK: - Injected dependencies

    private let coordinator: AudioSessionCoordinator
    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let conversationLookup: ConversationLookup
    private let userIdProvider: @MainActor () -> UserID?
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let micGate: any MicPermissionGate

    // Phase 25 (Plan 25-10) — book-aware RAG wiring. Both optional so the
    // presenter still works if/when these aren't injected (e.g. tests). When
    // BOTH bookSearch + bookId are present, RealtimeVoiceSession spawns a
    // BookContextResponder for the session. embedderPrewarm runs in parallel
    // with the key fetch when a book id is present.
    private let bookSearch: (any BookSearch)?
    private let embedderPrewarm: (@Sendable () async -> Void)?

    // MARK: - Per-session state

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
        embedderPrewarm: (@Sendable () async -> Void)? = nil
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
    }

    // MARK: - Public lifecycle

    /// Start a voice session bound to the conversation for `bookId`. Creates
    /// (or reuses) the conversation row via `ConversationLookup` so the
    /// transcript bridge has a stable `ConversationID` to upsert into.
    ///
    /// No-ops if a session is already in flight (presenter is single-session).
    func start(
        bookId: BookID?,
        initialQuote: String? = nil,
        bookContext: BookContextSnapshot? = nil
    ) async {
        // Single-session invariant: claim the presenting slot SYNCHRONOUSLY,
        // before the first suspension point. Two start() calls can interleave
        // under MainActor reentrancy (a double-tapped toolbar voice button, or
        // the toolbar button and the "Ask about this" affordance firing
        // together). If `isPresenting` were only set after the first `await`
        // (the conversation lookup), both calls would pass the guard and each
        // spin up a RealtimeVoiceSession — two WebRTC audio streams at once,
        // i.e. the "two voices / echo" bug. Claiming the slot here, before any
        // await, makes the guard reentrancy-safe: at most one live session.
        guard !isPresenting else { return }
        isPresenting = true
        currentBookId = bookId
        pendingInitialQuote = initialQuote
        currentBookContext = bookContext

        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            state.apply(status: .failed(reason: .unknown("Sign in required")))
            return
        }

        // Reset stale state from any prior failed session so the new
        // session starts from a clean `.idle`.
        state.reset()

        let conversation: Conversation
        do {
            conversation = try await conversationLookup.findOrCreate(
                userId: userId,
                bookId: bookId
            )
        } catch {
            Log.event("voice.presenter.lookup.failed", level: .error, data: [
                "error": String(describing: error),
            ])
            state.recordError(String(describing: error))
            state.apply(status: .failed(reason: .unknown(String(describing: error))))
            return
        }

        // Fresh adapter per session — the SDK's `Conversation` is not
        // reusable after disconnect (deinit closes the WebRTC peer).
        let adapter = RealtimeAPIAdapter()
        let fetcher = EphemeralKeyFetcher(workerClient: workerClient)
        let bridge = VoiceTranscriptBridge(
            messageStore: messageStore,
            dirtyHook: dirtyHook
        )

        // Phase 25 (Plan 25-10) — wire the BookContextResponder factory and
        // embedder prewarm into the session when we have a BookSearch + the
        // call is bound to a book. The factory closes over the search +
        // adapter; RealtimeVoiceSession invokes it after connect when bookId
        // is non-nil.
        let responderFactory: RealtimeVoiceSession.BookContextResponderFactory? = bookSearch.map { search in
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

        // Drive the transcript bridge in the background — persists final
        // fragments as MessageStore.upsert + fires dirty marks into Sync.
        let conversationId = conversation.id
        let presenterState = state
        bridgeTask?.cancel()
        // KEEP: F-P0-06 audit — bridge.consume(stream:conversationId:state:)
        // is a long-lived `for await` over the SDK's transcript AsyncStream.
        // The body awaits a stream + hops into the @MainActor `state` for
        // transcript updates; the underlying MessageStore.upsert is on an
        // actor. Wrapping in Task.detached would force MainActor.run on
        // every transcript fragment — strictly worse. UI-bound by design.
        bridgeTask = Task {
            await bridge.consume(
                stream: adapter.transcriptStream(),
                conversationId: conversationId,
                state: presenterState
            )
        }

        // Phase 25 (Plan 25-10) + reader-context integration — forward the
        // bookId so the session can spawn the BookContextResponder, AND thread
        // the reader's live `bookContext` snapshot (book identity + best-effort
        // page/outline signals) into the worker so OpenAI gets a book-aware
        // system prompt. The reader ALWAYS supplies a non-nil `outline`
        // (title/author) via `ReaderVoiceEntry`, so the model knows the book
        // even before any page text is captured. When `bookContext` is nil
        // (e.g. a library-shell launch) the snapshot fields fall back to nil,
        // reproducing the pre-integration bookId-only behavior.
        await session.start(
            language: "en",
            bookId: bookId,
            currentPage: bookContext?.currentPage,
            pageText: bookContext?.pageText,
            outline: bookContext?.outline,
            activeParagraphText: bookContext?.activeParagraphText
        )
    }

    /// Terminate the active session. Idempotent — calls into
    /// `RealtimeVoiceSession.end()` (which releases the audio session) and
    /// cancels the background transcript-bridge task.
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

    /// Restart a failed session with the SAME context it was started with.
    /// Captures the book id, prefilled quote, and book-context snapshot BEFORE
    /// `dismissFailure()` clears them, then restarts with all three — so Retry
    /// reproduces the original (book-aware, possibly quote-prefilled) session
    /// rather than degrading to a bookId-only one.
    func retry() async {
        let bookId = currentBookId
        let quote = pendingInitialQuote
        let context = currentBookContext
        dismissFailure()
        await start(bookId: bookId, initialQuote: quote, bookContext: context)
    }

    /// Reset to idle without starting a new session — used by the failure
    /// surface's Dismiss button. Cancels the bridge, drops the session, and
    /// clears the observable state so a subsequent `start(bookId:)` begins
    /// from `.idle`.
    func dismissFailure() {
        bridgeTask?.cancel()
        bridgeTask = nil
        session = nil
        isPresenting = false
        currentBookId = nil
        pendingInitialQuote = nil
        currentBookContext = nil
        state.reset()
    }
}
