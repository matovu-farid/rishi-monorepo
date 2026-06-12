//
//  VoiceSessionPresenter.swift
//  rishi
//
//  Phase 10 Plan 10-06 — app-layer presenter binding the chat panel's voice
//  button to the `RealtimeVoiceSession` actor and the SwiftUI
//  `.fullScreenCover` lifecycle. One instance is held by `AppDependencies`
//  for the app lifetime; ChatPanelHost reads `isPresenting` and calls
//  `start(bookId:)` / `end()`.
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
import RishiVoice
import RishiLogging

/// App-layer presenter binding the voice button in `ChatPanelHost` to the
/// `RealtimeVoiceSession` actor.
@MainActor
@Observable
final class VoiceSessionPresenter {

    /// Observable state pushed by `RealtimeVoiceSession`. SwiftUI binds via
    /// `@Bindable` on the host view.
    let state: VoiceSessionState

    /// Drives the `.fullScreenCover(isPresented:)` binding on `ChatPanelHost`.
    /// Flipped to `true` by `start(bookId:)` once a conversation is resolved;
    /// flipped to `false` by `end()` or `dismissFailure()`.
    private(set) var isPresenting: Bool = false

    /// The in-flight session, if any. `nil` outside of a presenting window.
    private(set) var session: RealtimeVoiceSession?

    // MARK: - Injected dependencies

    private let coordinator: AudioSessionCoordinator
    private let workerClient: WorkerClient
    private let messageStore: any MessageStore
    private let conversationLookup: ConversationLookup
    private let userIdProvider: @MainActor () -> UserID?
    private let dirtyHook: any VoiceTranscriptDirtyHook
    private let micGate: any MicPermissionGate

    // MARK: - Per-session state

    private var bridgeTask: Task<Void, Never>?

    init(
        coordinator: AudioSessionCoordinator,
        workerClient: WorkerClient,
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate()
    ) {
        self.state = VoiceSessionState()
        self.coordinator = coordinator
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.userIdProvider = userIdProvider
        self.dirtyHook = dirtyHook
        self.micGate = micGate
    }

    // MARK: - Public lifecycle

    /// Start a voice session bound to the conversation for `bookId`. Creates
    /// (or reuses) the conversation row via `ConversationLookup` so the
    /// transcript bridge has a stable `ConversationID` to upsert into.
    ///
    /// No-ops if a session is already in flight (presenter is single-session).
    func start(bookId: BookID?) async {
        guard !isPresenting else { return }
        guard let userId = userIdProvider() else {
            state.recordError("Sign in required")
            state.apply(status: .failed(reason: .unknown("Sign in required")))
            isPresenting = true
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
            isPresenting = true
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

        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: adapter,
            state: state
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

        isPresenting = true
        await session.start(language: "en")
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
        state.reset()
    }
}
