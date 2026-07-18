import Foundation
import RishiCore
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
/// realtime client. `end()` releases the mode. Every failure path releases
/// too — never strands the audio session.
///
/// Lifecycle FSM — legacy flow (`sessionCoordinator == nil`, unchanged since
/// before `2026-07-17-voice-session-flow-wiring.md`):
/// ```
/// idle → requestingMic → fetchingKey → connecting → live
///                                         ↓
///                                       live → reconnecting(N) → live (success)
///                                                              → failed(.networkLost) (3 attempts exhausted)
///                                       live → ending → ended
///   <any> → failed(reason)
/// ```
///
/// Lifecycle FSM — trial-voice-session flow (`sessionCoordinator != nil`,
/// added by `2026-07-17-voice-session-flow-wiring.md` for the no-card
/// credit trial / pricing launch):
/// ```
/// idle → requestingMic → creatingSession → connecting → registeringCall → live
///                                                                            ↓
///                                     live → reconnecting(N) → live   (WebRTC-level; unchanged mechanism)
///                                     live → ending → ended            (user-initiated end())
///                                     live → failed(.sessionTerminated) (control-WS session_ended)
///   <any> → failed(reason)
/// ```
/// The two flows share the mic-permission + audio-mode-claim prefix and the
/// teardown path; they diverge in how the ephemeral key is obtained and what
/// happens immediately after WebRTC `connect()` succeeds. See
/// `startLegacyFlow` / `startTrialVoiceSession`.
public actor RealtimeVoiceSession {

    public typealias BookContextResponderFactory = @Sendable (UUID) -> BookContextResponder

    private let micGate: any MicPermissionGate
    private let coordinator: AudioSessionCoordinator
    private let keyFetcher: any EphemeralKeyFetching
    private let client: any RealtimeClientAPI
    private let state: VoiceSessionState
    /// Non-nil selects the trial-voice-session flow. See
    /// `VoiceSessionPresenter.isTrialVoiceSessionFlowEnabled` for the
    /// production gate.
    private let sessionCoordinator: (any VoiceSessionCoordinating)?
    /// Builds a `ControlSocketConnecting` for a given `rishiSessionId`,
    /// supplying the `onTerminal` callback that the concrete
    /// `ControlWebSocketClient` requires at construction. Only consulted
    /// when `sessionCoordinator` is non-nil AND this is itself non-nil —
    /// see `openControlSocket`. Returning `nil` skips the control channel
    /// (e.g. feature flag off). The factory itself never needs to `throw`
    /// for a real `ControlWebSocketClient` — constructing one cannot fail;
    /// only `connect()` can, and that failure is handled inside
    /// `ControlWebSocketClient`'s reconnect loop, not here.
    private let controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)?
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
    /// multi-sample disconnect debounce, and the backoff reconnect ladder
    /// for the WebRTC connection. Unrelated to the control socket below —
    /// a control-WS drop never touches this controller, and vice versa;
    /// `ControlWebSocketClient` reconnects itself automatically and
    /// internally, so there is no analogous watchdog on this side.
    private var reconnect: ReconnectController?
    /// Responder consume() loop spawned at start when bookId is non-nil.
    private var responderTask: Task<Void, Never>?
    private var isEnding: Bool = false
    /// Current book snapshot used to seed the realtime session and reconnects.
    private var currentBookContext: BookContextSnapshot?
    /// Current voice language used for prompt + transcription + reconnects.
    private var currentLanguage: String?

    /// Set once `startTrialVoiceSession` successfully creates a Rishi voice
    /// session. Cleared on every teardown path (start failure, `end()`, or
    /// a control-WS terminal signal) so a stale id/nonce never leaks into a
    /// later session.
    private var activeVoiceSession: StartedVoiceSession?
    /// The control-WebSocket connection for the active trial voice session.
    /// Nil in the legacy flow, when `controlSocketFactory` is nil, or when
    /// the initial connect failed.
    private var controlSocket: (any ControlSocketConnecting)?
    private var controlMessageTask: Task<Void, Never>?

    public init(
        micGate: any MicPermissionGate,
        coordinator: AudioSessionCoordinator,
        keyFetcher: any EphemeralKeyFetching,
        client: any RealtimeClientAPI,
        state: VoiceSessionState,
        sessionCoordinator: (any VoiceSessionCoordinating)? = nil,
        controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)? = nil,
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
        self.sessionCoordinator = sessionCoordinator
        self.controlSocketFactory = controlSocketFactory
        self.responderFactory = responderFactory
        self.embedderPrewarm = embedderPrewarm
        self.backoff = backoff
        self.maxReconnects = maxReconnects
        self.disconnectConfirmations = disconnectConfirmations
        self.confirmationInterval = confirmationInterval
    }

    // MARK: - Public lifecycle

    /// Start a voice session. Branches into `startLegacyFlow` or
    /// `startTrialVoiceSession` depending on whether `sessionCoordinator`
    /// was injected; both share this mic-permission + audio-mode-claim
    /// prefix and the optional embedder prewarm.
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

        // Claim shared audio ownership up front so the coordinator knows this
        // voice session is the active owner before we fetch the key or connect.
        await coordinator.registerPreemption(for: .voice) { [weak self] in
            await self?.end()
        }
        await coordinator.requestActiveMode(.voice)

        let snapshot: BookContextSnapshot? = bookId.map { id in
            BookContextSnapshot(
                bookId: id,
                currentPage: currentPage,
                pageText: pageText,
                outline: outline,
                activeParagraphText: activeParagraphText
            )
        }
        currentBookContext = snapshot
        currentLanguage = language

        let prewarmTask: Task<Void, Never>? = {
            guard bookId != nil, let warm = embedderPrewarm else { return nil }
            return Task { await warm() }
        }()

        if let sessionCoordinator {
            await startTrialVoiceSession(
                using: sessionCoordinator,
                language: language,
                bookContext: snapshot,
                bookId: bookId,
                prewarmTask: prewarmTask
            )
        } else {
            await startLegacyFlow(
                language: language,
                bookContext: snapshot,
                bookId: bookId,
                prewarmTask: prewarmTask
            )
        }
    }

    /// Pre-existing behavior, unchanged: fetch a plain ephemeral key from
    /// `/api/realtime/client_secrets` (no Rishi session, no call-ID
    /// registration, no control WebSocket). Used whenever
    /// `sessionCoordinator` is nil.
    private func startLegacyFlow(
        language: String?,
        bookContext snapshot: BookContextSnapshot?,
        bookId: UUID?,
        prewarmTask: Task<Void, Never>?
    ) async {
        await update(.fetchingKey)

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
            try await client.connect(ephemeralKey: key.secret, bookContext: snapshot, language: language)
        } catch {
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            await fail(reason: .connect, message: String(describing: error))
            return
        }

        await update(.live)
        spawnResponderIfNeeded(bookId: bookId)
        Log.event("voice.session.live", level: .info, data: ["bookId": bookId?.uuidString ?? "<none>"])
        await reconnectController().startStatusObservation()
    }

    /// The no-card-credit-trial flow: create a Rishi voice session
    /// server-side, connect WebRTC with the returned client secret, register
    /// the captured OpenAI call ID, then open the control WebSocket. Any
    /// failure after WebRTC connects closes that connection immediately —
    /// never leaves an untracked session — per the spec's "Voice flow" step 7.
    private func startTrialVoiceSession(
        using sessionCoordinator: any VoiceSessionCoordinating,
        language: String?,
        bookContext snapshot: BookContextSnapshot?,
        bookId: UUID?,
        prewarmTask: Task<Void, Never>?
    ) async {
        await update(.creatingSession)

        let started: StartedVoiceSession
        do {
            started = try await sessionCoordinator.startSession(language: language, bookContext: snapshot)
        } catch {
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            let failure = VoiceSessionStartFailure.classify(error)
            await fail(reason: .sessionStart(failure), message: Self.sessionStartMessage(failure))
            return
        }
        activeVoiceSession = started

        await update(.connecting)
        do {
            try await client.connect(ephemeralKey: started.clientSecret, bookContext: snapshot, language: language)
        } catch {
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            activeVoiceSession = nil
            await fail(reason: .connect, message: String(describing: error))
            return
        }

        await update(.registeringCall)
        guard let callId = await client.providerCallId else {
            // Missing-Location-header case per the spec's "Voice flow" step
            // 7: fail closed, close the just-opened WebRTC connection, never
            // leave an untracked call running against a registered session.
            await client.disconnect()
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            activeVoiceSession = nil
            await fail(
                reason: .callRegistration(.missingCallId),
                message: Self.registrationMessage(.missingCallId)
            )
            return
        }

        do {
            try await sessionCoordinator.registerCall(
                rishiSessionId: started.rishiSessionId,
                callId: callId,
                nonce: started.nonce
            )
        } catch {
            await client.disconnect()
            prewarmTask?.cancel()
            await coordinator.releaseActiveMode(.voice)
            activeVoiceSession = nil
            let failure = VoiceSessionRegistrationFailure.classify(error)
            await fail(reason: .callRegistration(failure), message: Self.registrationMessage(failure))
            return
        }

        await update(.live)
        spawnResponderIfNeeded(bookId: bookId)
        openControlSocket(rishiSessionId: started.rishiSessionId)

        Log.event("voice.session.live", level: .info, data: [
            "bookId": bookId?.uuidString ?? "<none>",
            "rishiSessionId": started.rishiSessionId,
        ])
        await reconnectController().startStatusObservation()
    }

    public func end() async {
        isEnding = true
        await update(.ending)
        await reconnect?.cancel()
        controlMessageTask?.cancel(); controlMessageTask = nil
        responderTask?.cancel(); responderTask = nil
        await client.disconnect()
        await controlSocket?.disconnect()
        await coordinator.releaseActiveMode(.voice)
        await update(.ended)
        Log.event("voice.session.ended", level: .info)
        currentBookContext = nil
        currentLanguage = nil
        activeVoiceSession = nil
        controlSocket = nil
    }

    // MARK: - Control WebSocket (trial-voice-session flow only)

    /// Opens the control WebSocket for a newly-registered session and spawns
    /// its one consumer task (the general `messages` stream). Reconnection
    /// on an unexpected drop is fully automatic and internal to
    /// `ControlWebSocketClient` — there is no connection-state stream to
    /// watch and no reconnect call for this method (or anything else in
    /// this actor) to make. Termination is delivered exclusively through
    /// the `onTerminal` callback supplied to `controlSocketFactory` below,
    /// per `ControlWebSocketClient`'s own contract ("do not rely on
    /// filtering `messages` ... instead"). A failed initial `connect()`
    /// is not surfaced as a throw (the real `connect()` doesn't throw) —
    /// `ControlWebSocketClient` just starts its own reconnect loop
    /// silently, so this session's control channel self-heals without any
    /// action here. If `controlSocketFactory` is nil (the default until
    /// `VoiceSessionPresenter` is updated to wire it — see Task 12), the
    /// session runs without the allowance/warning UI; server-side
    /// enforcement is unaffected either way.
    private func openControlSocket(rishiSessionId: String) {
        guard let controlSocketFactory else { return }
        guard let socket = controlSocketFactory(rishiSessionId, { [weak self] signal in
            await self?.terminateFromControlSocket(reason: signal.reason)
        }) else { return }
        controlSocket = socket

        controlMessageTask = Task { [weak self] in
            guard let self else { return }
            await socket.connect()
            for await message in socket.messages {
                await self.handleControlMessage(message)
            }
        }
    }

    /// Handles one decoded `ControlMessage`. Deliberately does NOT act on
    /// `.sessionEnded` or a terminal `.snapshot` here — per
    /// `ControlWebSocketClient`'s contract, termination is delivered
    /// exclusively through the mandatory `onTerminal` callback passed to
    /// `controlSocketFactory` in `openControlSocket`, never by filtering
    /// this stream. Acting on it in both places would risk a double
    /// teardown race; `terminateFromControlSocket`'s `isEnding` guard
    /// protects against that anyway, but there is no reason to rely on it.
    private func handleControlMessage(_ message: ControlMessage) async {
        switch message {
        case .allowanceRemaining(_, let remainingTrialCredits, let remainingVoiceChatSeconds, let remainingIntervals):
            await MainActor.run {
                state.applyAllowance(
                    remainingTrialCredits: remainingTrialCredits,
                    remainingVoiceChatSeconds: remainingVoiceChatSeconds,
                    remainingIntervals: remainingIntervals
                )
            }
        case .sessionEnding:
            await MainActor.run { state.applySessionEndingWarning() }
        case .sessionError(_, let code, let message):
            // Not necessarily terminal (setup/reconciliation failures per
            // the spec) — surface it without tearing the session down.
            Log.event("voice.session.control.error", level: .warning, data: [
                "code": code,
                "message": message,
            ])
            await MainActor.run { state.recordError(message) }
        case .snapshot(_, _, let remainingTrialCredits, let remainingVoiceChatSeconds, let remainingIntervals, _):
            // A non-terminal snapshot (pendingRegistration/active) just
            // refreshes the allowance HUD with the authoritative current
            // value; a terminal snapshot is handled exclusively via
            // `onTerminal`, never here.
            await MainActor.run {
                state.applyAllowance(
                    remainingTrialCredits: remainingTrialCredits,
                    remainingVoiceChatSeconds: remainingVoiceChatSeconds,
                    remainingIntervals: remainingIntervals
                )
            }
        case .sessionEnded:
            break
        }
    }

    /// The server-driven terminal path, invoked from the `onTerminal`
    /// callback passed to `controlSocketFactory` (i.e. a `session_ended`
    /// message or a terminal `snapshot`). Mirrors `end()`'s teardown order
    /// but lands in `.failed(.sessionTerminated(reason:))` rather than
    /// `.ended`, so `VoiceFailureAlert` shows the terminal reason to the
    /// user, per the spec's "on its terminal signal: stop the microphone,
    /// tear down the WebRTC connection, and show the terminal reason to
    /// the user via the existing error/status UI."
    private func terminateFromControlSocket(reason: ControlTerminalReason) async {
        guard !isEnding else { return }
        isEnding = true
        Log.event("voice.session.control.terminal", level: .info, data: ["reason": String(describing: reason)])
        await reconnect?.cancel()
        controlMessageTask?.cancel(); controlMessageTask = nil
        responderTask?.cancel(); responderTask = nil
        await client.disconnect()
        await controlSocket?.disconnect()
        await coordinator.releaseActiveMode(.voice)
        await fail(reason: .sessionTerminated(reason: reason), message: Self.sessionTerminatedMessage(reason))
        currentBookContext = nil
        currentLanguage = nil
        activeVoiceSession = nil
        controlSocket = nil
    }

    // MARK: - Reconnect (WebRTC-level; unaffected by this plan)

    /// Lazily build the `ReconnectController`, forwarding the four reconnect
    /// knobs + wiring the callbacks back into this session's FSM. Built once
    /// and reused — `startStatusObservation()` is idempotent (re-arms the
    /// poll). Deliberately still driven by `keyFetcher` (the legacy plain-key
    /// endpoint) even in the trial-voice-session flow — see "Production
    /// gotchas" in `2026-07-17-voice-session-flow-wiring.md` for why a
    /// WebRTC-level reconnect does not re-run session-create/register-call.
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
                await self.reconnectController().startStatusObservation()
            },
            onExhausted: { [weak self] in
                guard let self else { return }
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
            bookContext: currentBookContext,
            language: currentLanguage,
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

    private func spawnResponderIfNeeded(bookId: UUID?) {
        if let bookId, let factory = responderFactory {
            let responder = factory(bookId)
            Log.event("voice.session.tool_responder.started", level: .info, data: [
                "bookId": bookId.uuidString,
            ])
            responderTask = Task {
                await responder.consume(stream: client.toolCallStream())
            }
        } else {
            Log.event("voice.session.tool_responder.skipped", level: .info, data: [
                "bookId": bookId?.uuidString ?? "<none>",
                "hasFactory": String(responderFactory != nil),
            ])
        }
    }

    /// Readable, user-facing message for a classified key-fetch failure.
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

    private static func sessionStartMessage(_ failure: VoiceSessionStartFailure) -> String {
        switch failure {
        case .alreadyActive:
            return "You already have a voice session running. Close it before starting another."
        case .insufficientCredits:
            return "You've used all 100 trial voice credits. Upgrade to keep using voice chat."
        case .mintFailed:
            return "The voice service couldn't start your session. Try again in a moment."
        case .unauthorized:
            return "Your session expired. Sign in again to use voice chat."
        case .serviceUnavailable:
            return "The voice service is temporarily unavailable. Please try again soon."
        case .network:
            return "Check your internet connection and try again."
        case .unknown(let detail):
            return "Couldn't start the session. \(detail)"
        }
    }

    private static func registrationMessage(_ failure: VoiceSessionRegistrationFailure) -> String {
        switch failure {
        case .missingCallId, .invalidBody, .sessionIdMismatch, .nonceInvalid:
            return "Couldn't confirm the voice connection. Please try again."
        case .noActiveSession:
            return "That voice session is no longer active. Start a new one."
        case .callAlreadyRegistered, .nonceReplayed:
            return "This voice connection was already confirmed. Please try again."
        case .unauthorized:
            return "Your session expired. Sign in again to use voice chat."
        case .serviceUnavailable:
            return "The voice service is temporarily unavailable. Please try again soon."
        case .network:
            return "Check your internet connection and try again."
        case .unknown(let detail):
            return "Couldn't confirm the voice connection. \(detail)"
        }
    }

    private static func sessionTerminatedMessage(_ reason: ControlTerminalReason) -> String {
        switch reason {
        case .voiceSessionTimeCap:
            return "This voice session reached its time limit."
        case .trialCreditsExhausted:
            return "You've used all 100 trial voice credits. Upgrade to keep using voice chat."
        case .planVoiceAllowanceExhausted:
            return "You've used your plan's Voice Chat time for this period."
        case .registrationTimeout:
            return "We couldn't confirm the voice connection in time. Please try again."
        case .providerHangupFailed:
            return "Voice chat ended unexpectedly. Please try again."
        case .unknown(let raw):
            return "Voice chat ended (\(raw))."
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
