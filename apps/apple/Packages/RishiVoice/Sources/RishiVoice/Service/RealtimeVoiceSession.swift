import Foundation
import RishiAPI
import RishiCore
import RishiAudio
import RishiLogging
import RishiSearch

/// Voice session lifecycle actor. Drives the FSM, coordinates audio
/// session ownership, runs the reconnect loop, and pushes status changes
/// into the @MainActor `VoiceSessionState`.
///
/// CONTRACT — VOICE-08: No `import CallKit` anywhere. Session end is
/// explicit via `end()`. Smoke test in `PackageSmokeTests` enforces this
/// at the package level.
///
/// CONTRACT — VOICE-04: `start()` acquires `.voice` mode on the
/// `AudioSessionCoordinator` BEFORE handing the ephemeral key to the
/// realtime client. `end()` releases the mode. Every failure path
/// (`micDenied`, `keyFetch`, `connect`, `networkLost`) releases too —
/// never strands the audio session.
///
/// Lifecycle FSM:
/// ```
/// idle → requestingMic → fetchingKey → connecting → live
///                                         ↓
///                                       live → reconnecting(N) → live (success)
///                                                              → failed(.networkLost) (3 attempts exhausted)
///                                       live → ending → ended
///   <any> → failed(reason)
/// ```
public actor RealtimeVoiceSession {

    /// Factory closure type for the per-session Book-Context Responder.
    /// Plan 25-10 spawns the responder at connect-time when `start(bookId:)`
    /// supplies a non-nil book id AND a factory was passed at init. Returning
    /// a `BookContextResponder` (not a protocol) keeps the responder's actor
    /// isolation contractual without forcing tests to mock the search loop.
    public typealias BookContextResponderFactory = @Sendable (UUID) -> BookContextResponder

    private let micGate: any MicPermissionGate
    private let coordinator: AudioSessionCoordinator
    private let keyFetcher: any EphemeralKeyFetching
    private let client: any RealtimeClientAPI
    private let state: VoiceSessionState
    private let responderFactory: BookContextResponderFactory?
    private let embedderPrewarm: (@Sendable () async -> Void)?
    private let backoff: @Sendable (Int) -> Duration
    private let maxReconnects: Int
    /// How many additional confirming polls must ALSO read `.disconnected`
    /// before we treat a drop as real and reconnect. Guards against tearing
    /// down a healthy session on a single transient status sample.
    private let disconnectConfirmations: Int
    /// Delay between confirming polls during `confirmDisconnect()`.
    private let confirmationInterval: Duration

    /// The reconnect engine (plan 34-13). Owns the 10Hz status poll, the
    /// multi-sample disconnect debounce, and the backoff reconnect ladder.
    /// Constructed lazily in `start()` (it needs `self` in its callbacks) so the
    /// session's public `init` stays unchanged. The four reconnect knobs are
    /// stored above and forwarded when the controller is built.
    private var reconnect: ReconnectController?
    /// Responder consume() loop spawned at start when bookId is non-nil. Lives
    /// for the life of the session; cancelled in `end()` BEFORE `client.disconnect()`
    /// so any in-flight tool-call processing stops cleanly before the stream
    /// finishes underneath it.
    private var responderTask: Task<Void, Never>?
    private var isEnding: Bool = false

    public init(
        micGate: any MicPermissionGate,
        coordinator: AudioSessionCoordinator,
        keyFetcher: any EphemeralKeyFetching,
        client: any RealtimeClientAPI,
        state: VoiceSessionState,
        responderFactory: BookContextResponderFactory? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        backoff: @escaping @Sendable (Int) -> Duration = { attempt in
            // Spike B pattern: 1s, 2s, 4s exponential backoff.
            switch attempt {
            case 1:  return .seconds(1)
            case 2:  return .seconds(2)
            default: return .seconds(4)
            }
        },
        maxReconnects: Int = 3,
        disconnectConfirmations: Int = 3,
        confirmationInterval: Duration = .milliseconds(150)
    ) {
        self.micGate = micGate
        self.coordinator = coordinator
        self.keyFetcher = keyFetcher
        self.client = client
        self.state = state
        self.responderFactory = responderFactory
        self.embedderPrewarm = embedderPrewarm
        self.backoff = backoff
        self.maxReconnects = maxReconnects
        self.disconnectConfirmations = disconnectConfirmations
        self.confirmationInterval = confirmationInterval
    }

    // MARK: - Public lifecycle

    /// Start a voice session.
    ///
    /// Phase 25 (Plan 25-10) extends the signature with optional book-context
    /// parameters. When `bookId` is non-nil the session:
    ///   - Threads a `BookContextSnapshot` into the worker via the key fetcher
    ///     (so OpenAI gets a book-aware system prompt + `bookContext` tool).
    ///   - Spawns a `BookContextResponder` task (if a `responderFactory` was
    ///     wired at init) consuming the client's `toolCallStream()`. The
    ///     responder is cancelled in `end()` BEFORE the client disconnects.
    ///   - Runs the optional `embedderPrewarm` closure IN PARALLEL with the
    ///     key fetch (closes RESEARCH OQ-4 — hides the Core ML cold-load).
    ///
    /// When `bookId` is nil all five book-context parameters are ignored;
    /// the session falls back to the pre-Phase-25 transcript-only behavior.
    public func start(
        language: String? = "en",
        bookId: UUID? = nil,
        currentPage: Int? = nil,
        pageText: String? = nil,
        outline: BookOutlineDTO? = nil,
        activeParagraphText: String? = nil
    ) async {
        await update(.requestingMic)

        let decision = await micGate.request()
        guard decision == .granted else {
            await fail(reason: .micDenied, message: "Microphone permission denied")
            return
        }

        // Single-audio-owner invariant: let the coordinator end this session if
        // another owner (read-aloud TTS) takes the session. end() is our full
        // teardown and releases .voice itself. [weak self] so the coordinator's
        // stored closure never retains the per-session actor.

        await update(.fetchingKey)

        // Construct the book-context snapshot if we have a book id; otherwise
        // pass nil so the worker reproduces the pre-Phase-25 behavior.
        let snapshot: BookContextSnapshot? = bookId.map { id in
            BookContextSnapshot(
                bookId: id,
                currentPage: currentPage,
                pageText: pageText,
                outline: outline,
                activeParagraphText: activeParagraphText
            )
        }

        // Plan 25-10 / RESEARCH OQ-4 — run the embedder prewarm in PARALLEL
        // with the key fetch so the first `bookContext` tool call doesn't
        // pay the ~500 ms Core ML cold-load cost on top of the network round
        // trip. Only spawn the prewarm task when both a book id AND a prewarm
        // closure are present — book-less sessions don't need the embedder.
        let prewarmTask: Task<Void, Never>? = {
            guard bookId != nil, let warm = embedderPrewarm else { return nil }
            return Task { await warm() }
        }()

        let key: EphemeralKey
        do {
            key = try await keyFetcher.fetch(language: language, bookContext: snapshot)
        } catch {
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            let failure = KeyFetchFailure.classify(error)
            await fail(reason: .keyFetch(failure), message: Self.keyFetchMessage(failure))
            return
        }

        await update(.connecting)
        do {
            try await client.connect(ephemeralKey: key.secret)
        } catch {
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            await fail(reason: .connect, message: String(describing: error))
            return
        }

        await update(.live)

        // Spawn the Responder consume loop AFTER the client connects (so the
        // client's tool-call stream is live). Only spawn when a factory was
        // wired AND we actually have a book id — a book-less session has no
        // search target.
        if let bookId, let factory = responderFactory {
            let responder = factory(bookId)
            responderTask = Task {
                await responder.consume(stream: client.toolCallStream())
            }
        }

        Log.event("voice.session.live", level: .info, data: [
            "bookId": bookId?.uuidString ?? "<none>",
        ])
        await reconnectController().startStatusObservation()
    }

    public func end() async {
        isEnding = true
        await update(.ending)
        await reconnect?.cancel()
        // Phase 25 (Plan 25-10) — cancel the Responder BEFORE client.disconnect()
        // so any in-flight tool-call processing sees Task.isCancelled and
        // skips its sendToolResult. Disconnect would also finish the stream
        // and break the consume loop, but cancelling first guarantees an
        // in-flight search doesn't race a phantom sendToolResult.
        responderTask?.cancel(); responderTask = nil
        await client.disconnect()
        await coordinator.releaseActiveMode(.voice)
        await update(.ended)
        Log.event("voice.session.ended", level: .info)
    }

    // MARK: - Reconnect

    /// Lazily build the `ReconnectController`, forwarding the four reconnect
    /// knobs + wiring the callbacks back into this session's FSM. Built once and
    /// reused — `startStatusObservation()` is idempotent (re-arms the poll).
    private func reconnectController() -> ReconnectController {
        if let reconnect { return reconnect }
        let callbacks = ReconnectController.Callbacks(
            isEnding: { [weak self] in await self?.readIsEnding() ?? true },
            onReconnecting: { [weak self] attempt in
                await self?.update(.reconnecting(attempt: attempt))
            },
            onReconnected: { [weak self] _ in
                guard let self else { return }
                await self.update(.live)
                // Re-arm the status poll after a successful reconnect.
                await self.reconnectController().startStatusObservation()
            },
            onExhausted: { [weak self] in
                guard let self else { return }
                // All reconnect attempts failed — release the audio session.
                await self.coordinator.releaseActiveMode(.voice)
                await self.fail(
                    reason: .networkLost,
                    message: "Reconnect exhausted after \(self.maxReconnects) attempts"
                )
            }
        )
        let controller = ReconnectController(
            client: client,
            keyFetcher: keyFetcher,
            backoff: backoff,
            maxReconnects: maxReconnects,
            disconnectConfirmations: disconnectConfirmations,
            confirmationInterval: confirmationInterval,
            callbacks: callbacks
        )
        reconnect = controller
        return controller
    }

    /// Probe for the `isEnding` race guard, read on the session actor so the
    /// `ReconnectController` (a separate actor) never touches the FSM flag
    /// directly. Returns `true` if the session is gone (treat as ending).
    private func readIsEnding() -> Bool { isEnding }

    // MARK: - Helpers

    /// Readable, user-facing message for a classified key-fetch failure.
    /// Derives from the case rather than dumping `String(describing:)` so the
    /// recorded error string is presentable, not a raw enum/error dump.
    private static func keyFetchMessage(_ failure: KeyFetchFailure) -> String {
        switch failure {
        case .unauthorized:
            return "Your session expired. Sign in again to use voice chat."
        case .subscriptionRequired:
            return "Voice chat is a Pro feature."
        case .serviceUnavailable:
            return "The voice service is temporarily unavailable. Please try again soon."
        case .network:
            return "Check your internet connection and try again."
        case .unknown(let detail):
            return "Couldn't start the session. \(detail)"
        }
    }

    @MainActor
    private func push(status: VoiceSessionStatus, error: String? = nil) {
        state.apply(status: status)
        if let error { state.recordError(error) }
    }

    private func update(_ status: VoiceSessionStatus) async {
        await push(status: status)
    }

    private func fail(reason: VoiceSessionFailureReason, message: String) async {
        Log.event("voice.session.failed", level: .error, data: [
            "reason": String(describing: reason),
            "message": message,
        ])
        await MainActor.run {
            state.apply(status: .failed(reason: reason))
            state.recordError(message)
        }
    }
}
