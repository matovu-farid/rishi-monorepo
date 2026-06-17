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
    /// flipped to `false` by `end()`, `enterFailure(reason:)`, or
    /// `clearFailure()`.
    private(set) var isPresenting: Bool = false

    /// The active failure surface, if any. Non-nil drives a native `.alert`
    /// on `SignedInView` (presented on the library/reader UNDERNEATH the now
    /// dismissed voice cover) instead of the deleted full-screen
    /// `VoiceErrorView`. Published ONLY once the voice cover has finished
    /// dismissing (see `pendingFailure` / `promotePendingFailure()`); cleared
    /// by `clearFailure()` (Dismiss) or `retry()` (Try again).
    private(set) var failure: VoiceFailureAlert?

    /// A failure that has been recorded but is waiting for the voice cover to
    /// finish dismissing before it can be shown as an `.alert`.
    ///
    /// An `.alert` and the `.fullScreenCover` are presented from the SAME view
    /// (`SignedInView`); SwiftUI/Catalyst cannot present the alert while the
    /// cover is mid-dismiss, so publishing `failure` in the same transaction
    /// that flips `isPresenting` to `false` silently drops the alert. Instead
    /// `enterFailure` stashes here and flips the cover off; the cover's
    /// `onDismiss` calls `promotePendingFailure()` to publish `failure` once
    /// the cover is gone and the alert can present without contention.
    private(set) var pendingFailure: VoiceFailureAlert?

    /// The in-flight session, if any. `nil` outside of a presenting window.
    private(set) var session: RealtimeVoiceSession?

    /// The book context the current presentation is bound to. Set at the top
    /// of `start`, cleared by `end()` / `clearFailure()`. The
    /// `VoiceSessionHost` reads this to resolve the text-chat conversation
    /// when the user opens the in-voice text sheet.
    private(set) var currentBookId: BookID?

    /// The quote forwarded from the reader's "Ask about this" affordance, if
    /// any. Set at the top of `start`, cleared by `end()` / `clearFailure()`.
    /// Non-nil means the host should auto-open the text-chat sheet prefilled
    /// with this quote.
    private(set) var pendingInitialQuote: String?

    /// The reader's book-context snapshot (title/author/page/active paragraph)
    /// the current presentation was started with, if any. Set at the top of
    /// `start`, cleared by `end()` / `clearFailure()`. Retained so `retry()`
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

    // Injection seams for the realtime client + ephemeral-key fetcher. Default
    // to the production constructions so prod behavior is unchanged; UI-test
    // wiring (AppDependencies under RISHI_UITEST) swaps in offline fakes so a
    // session can reach `.live` with no network. The client factory closes
    // over nothing and is invoked once per `start()` (the SDK `Conversation`
    // is not reusable after disconnect — the same per-session contract the
    // hardcoded construction had). The key-fetcher factory closes over the
    // injected `workerClient` for the production default.
    private let clientFactory: @MainActor () -> any RealtimeClientAPI
    private let keyFetcherFactory: @MainActor () -> any EphemeralKeyFetching

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
        // Default to the exact production construction so prod is unchanged.
        // The key-fetcher default captures `workerClient` (the same value the
        // hardcoded `EphemeralKeyFetcher(workerClient:)` used).
        self.clientFactory = clientFactory ?? { RealtimeAPIAdapter() }
        self.keyFetcherFactory = keyFetcherFactory ?? { EphemeralKeyFetcher(workerClient: workerClient) }
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
        // Re-arm the failure surface so a prior failed attempt whose alert was
        // never dismissed (e.g. it was dropped by a presentation collision)
        // cannot wedge this one via `enterFailure`'s idempotency guard.
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
            enterFailure(reason: .unknown(String(describing: error)))
            return
        }

        // Fresh client per session — the SDK's `Conversation` is not
        // reusable after disconnect (deinit closes the WebRTC peer). In
        // production `clientFactory` builds a `RealtimeAPIAdapter`; under
        // RISHI_UITEST it builds an offline fake (see AppDependencies) so the
        // session can reach `.live` with no network.
        let adapter = clientFactory()
        let fetcher = keyFetcherFactory()
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

        // `session.start()` applies a terminal `.failed` synchronously for
        // startup failures (e.g. `.micDenied` when permission is already
        // denied — `micGate.request()` returns instantly without a system
        // prompt). That can happen BEFORE the cover renders a frame, so the
        // `VoiceSessionHost` `.onChange(of: status)` would miss it and the
        // cover would linger on an empty state. Route it here, imperatively,
        // so the alert surfaces regardless of view timing. Live failures that
        // occur later (network loss mid-session) are caught by the host's
        // onChange while the cover is on screen.
        if case .failed(let reason) = state.status {
            enterFailure(reason: reason)
        }
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
    /// `clearFailure()` clears them, then restarts with all three — so Retry
    /// reproduces the original (book-aware, possibly quote-prefilled) session
    /// rather than degrading to a bookId-only one.
    func retry() async {
        let bookId = currentBookId
        let quote = pendingInitialQuote
        let context = currentBookContext
        clearFailure()
        await start(bookId: bookId, initialQuote: quote, bookContext: context)
    }

    /// Clear the failure surface and reset to idle without starting a new
    /// session — backs the native `.alert`'s Dismiss button (and is called by
    /// `retry()` before restarting). Drops the `failure` value, cancels the
    /// bridge, releases the session, and clears the observable state so a
    /// subsequent `start(bookId:)` begins from `.idle`.
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

    // MARK: - Failure routing

    /// Single entry point for every `.failed(reason:)` transition. Builds the
    /// `VoiceFailureAlert` (caller copy from `state.lastError` wins over the
    /// reason's default body), then dismisses the voice cover by flipping
    /// `isPresenting` to `false`. The alert itself is published only after the
    /// cover finishes dismissing — see `pendingFailure` — so it does not
    /// collide with the cover's dismissal on the same view. Keeps
    /// `state.status` as `.failed(reason:)`.
    ///
    /// Idempotent: re-entry while a failure is already recorded is a no-op, so
    /// the `VoiceSessionHost` `.onChange(of:)` that drives the async/live
    /// failure paths can fire without double-handling.
    func enterFailure(reason: VoiceSessionFailureReason) {
        guard failure == nil, pendingFailure == nil else { return }
        state.apply(status: .failed(reason: reason))
        let alert = VoiceFailureAlert(reason: reason, message: state.lastError)
        if isPresenting {
            // Cover is on screen: stash, dismiss it, and publish the alert from
            // the cover's `onDismiss` (via `promotePendingFailure`).
            pendingFailure = alert
            isPresenting = false
        } else {
            // No cover to dismiss — present the alert immediately.
            failure = alert
        }
    }

    /// Publish a `pendingFailure` as the live `failure` once the voice cover
    /// has finished dismissing. Wired to the cover's `onDismiss`. A no-op when
    /// nothing is pending (e.g. a normal session end).
    func promotePendingFailure() {
        guard let pending = pendingFailure else { return }
        pendingFailure = nil
        failure = pending
    }
}
