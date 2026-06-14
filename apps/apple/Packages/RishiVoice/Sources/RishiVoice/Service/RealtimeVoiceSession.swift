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

    private var reconnectTask: Task<Void, Never>?
    private var statusObservationTask: Task<Void, Never>?
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
        maxReconnects: Int = 3
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

        // Acquire audio session BEFORE fetching the key. If the key fetch
        // fails we already own the session and must release it cleanly.
        await coordinator.requestActiveMode(.voice)
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
            await fail(reason: .keyFetch, message: String(describing: error))
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
        startStatusObservation()
    }

    public func end() async {
        isEnding = true
        await update(.ending)
        statusObservationTask?.cancel()
        statusObservationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
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

    private func startStatusObservation() {
        statusObservationTask?.cancel()
        // KEEP: session is an actor; status poll runs on the actor's executor
        // at 10Hz to detect reconnect-eligible disconnects. Observation push
        // refactor deferred to v1.1 ADR backlog (plan 19-12) — Realtime SDK
        // does not expose a status stream today.
        statusObservationTask = Task { [weak self] in
            guard let self else { return }
            // Poll client status at 10Hz — Spike B confirmed status is a
            // property, not a stream. Higher cadence keeps reconnect tests
            // fast without affecting production behavior.
            while !Task.isCancelled {
                let status = await self.client.currentStatus()
                if status == .disconnected {
                    await self.handleTransientDisconnect()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func handleTransientDisconnect() async {
        // If end() is already in flight, ignore the disconnect — the
        // explicit teardown owns the termination path.
        if isEnding { return }
        Log.event("voice.session.disconnect.transient", level: .warning)
        for attempt in 1...maxReconnects {
            if isEnding { return }
            await update(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: backoff(attempt))
            if isEnding { return }
            // Refresh the ephemeral key — secrets are short-lived. If the
            // key fetch fails on reconnect, count it as a failed attempt.
            let newKey: EphemeralKey
            do {
                newKey = try await keyFetcher.fetch(language: "en")
            } catch {
                continue
            }
            do {
                try await client.connect(ephemeralKey: newKey.secret)
                await update(.live)
                startStatusObservation()
                Log.event("voice.session.reconnected", level: .info, data: [
                    "attempt": String(attempt),
                ])
                return
            } catch {
                continue
            }
        }
        // All reconnect attempts failed — release the audio session.
        await coordinator.releaseActiveMode(.voice)
        await fail(reason: .networkLost, message: "Reconnect exhausted after \(maxReconnects) attempts")
    }

    // MARK: - Helpers

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
