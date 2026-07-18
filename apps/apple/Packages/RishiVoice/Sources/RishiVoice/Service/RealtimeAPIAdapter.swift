import Foundation
import RishiCore
import UI
import RealtimeAPI
import RishiLogging

typealias SDKConversation = UI.Conversation
typealias SDKSession = Core.Session

/// Production impl of `RealtimeClientAPI` backed by `swift-realtime-openai`'s
/// `Conversation` type.
///
/// `Conversation` is `@MainActor`-isolated `@Observable` (see UI/Conversation.swift
/// in the pinned SDK at SHA `46f393d…`). All access to the wrapped instance
/// therefore hops to the main actor. The adapter itself is `@unchecked Sendable`
/// because the optional `conversation` reference is mutated under an `NSLock`
/// from off-main contexts; the stored value is only read on `@MainActor` and
/// reset under the lock during disconnect.
///
/// SRP decomposition (plan 34-13): the adapter is now a thin `RealtimeClientAPI`
/// conformer that holds the `Conversation` + stream continuations under the lock
/// and delegates to four INTERNAL collaborators it constructs itself (so the
/// public `init()` signature is unchanged and AppDependencies is untouched):
///   - `WebRTCAudioUnitController` — process-global WebRTC audio-unit control.
///   - `RealtimeSessionConfigBuilder` — OpenAI session/audio config.
///   - `RealtimeEventPump` — the three SDK→stream polling loops + dedupe.
///   - `RealtimeToolCallDispatcher` — tool-call readiness + result encoding.
///
/// Transcript pump path (per Plan 10-02 note): the pinned SDK exposes finalized
/// transcripts via `Conversation.entries: [Item]` where `case .message(Item.Message)`
/// carries `[Item.Message.Content]` whose `.text` accessor unifies text +
/// audio-transcript content. The pump snapshots `entries.count` between
/// SDK ticks and emits a transcript event for each NEW entry.
public final class RealtimeAPIAdapter: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var conversation: SDKConversation?

    // Persistent stream continuations across the adapter's lifetime. New
    // consumers re-call to get a new stream backed by the same continuation
    // slot — finishing on `disconnect()`.
    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    // The OpenAI-assigned Realtime call ID (the `call_id` from the `Location`
    // header returned by `POST /v1/realtime/calls`), captured on a successful
    // `connect()`. `nil` before the first successful connect, after every
    // `disconnect()`/`teardownActiveConversation()`, or if the provider's
    // response was missing/malformed the `Location` header (see
    // `WebRTCConnector.fetchRemoteSDP` for that capture-failure case). A
    // later plan (voice-session-flow-wiring) reads this immediately after
    // `connect(...)` returns successfully and registers it with the Worker;
    // that plan must treat `nil` here as equivalent to a registration
    // failure (close the connection, show a retryable error) — this plan
    // does not implement that closing behavior.
    private var _providerCallId: String?

    // Internal collaborators — constructed here so the public `init()` is
    // unchanged. `let` (stateless / handle-holding); behavior identical.
    private let audioUnit = WebRTCAudioUnitController()
    private let configBuilder = RealtimeSessionConfigBuilder()
    private let toolDispatcher = RealtimeToolCallDispatcher()
    private let pump = RealtimeEventPump()

    /// See the `_providerCallId` doc comment above for the full contract.
    public var providerCallId: String? {
        lock.withLock { _providerCallId }
    }

    public init() {}

    // MARK: - White-box test seams (preserved)

    // These forward to the pump / config builder / dispatcher so the existing
    // `@testable` tests keep pointing at the same symbols after decomposition.

    internal var errorPump: Task<Void, Never>? {
        get { pump.errorPump }
        set { pump.errorPump = newValue }
    }

    internal var transcriptPump: Task<Void, Never>? {
        get { pump.transcriptPump }
        set { pump.transcriptPump = newValue }
    }

    internal var toolCallPump: Task<Void, Never>? {
        get { pump.toolCallPump }
        set { pump.toolCallPump = newValue }
    }

    static func makePCM24kFormat() -> SDKSession.AudioFormat {
        RealtimeSessionConfigBuilder.makePCM24kFormat()
    }

    static var inputNoiseReduction: SDKSession.Audio.Input.NoiseReduction {
        RealtimeSessionConfigBuilder.inputNoiseReduction
    }

    /// Build the exact realtime session payload the adapter hands to the SDK.
    /// Exposed internally so tests can verify adapter wiring without needing a
    /// live WebRTC peer.
    internal func makeConfiguredSession(
        bookContext: BookContextSnapshot?,
        language: String? = "en"
    ) -> SDKSession {
        var session = SDKSession(
            audio: configBuilder.makeSessionAudio(language: language),
            instructions: "",
            model: .gptRealtime
        )
        configBuilder.configure(session: &session, bookContext: bookContext, language: language)
        return session
    }

    /// Wait for the realtime session to become visible on the conversation and
    /// confirm that the expected book-aware config landed.
    static func waitUntilConfiguredSession(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50),
        sessionSnapshot: @escaping @Sendable () async -> SDKSession?
    ) async throws -> SDKSession {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if let session = await sessionSnapshot(),
               sessionHasBookContext(session) {
                return session
            }
            try await Task.sleep(for: pollInterval)
        }

        if let session = await sessionSnapshot(),
           sessionHasBookContext(session) {
            return session
        }

        throw RealtimeClientError(
            code: "session_not_ready",
            message: "Realtime session never exposed the configured book tool and instructions"
        )
    }

    internal func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
        toolDispatcher.isArgumentsReady(fc: fc)
    }

    // MARK: - RealtimeClientAPI

    public func connect(
        ephemeralKey: String,
        bookContext: BookContextSnapshot? = nil,
        language: String? = nil
    ) async throws {
        // Single-peer invariant: opening a new peer always closes the old one
        // first. On RECONNECT the session re-calls `connect()` WITHOUT a
        // preceding `disconnect()` (so transcript/tool/error streams stay
        // alive). Without this teardown, the prior pump Tasks keep polling the
        // OLD `Conversation`, retaining its WebRTC peer + audio — producing two
        // concurrent voices. Tearing down here cancels those pumps and drops the
        // old `Conversation` so its `deinit` closes the peer, without touching
        // the stream continuations.
        // Ensure WebRTC manual-audio mode is on exactly once (process-global,
        // idempotent), BEFORE any WebRTC audio init.
        audioUnit.enableManualModeOnce()
        await teardownActiveConversation()
        Log.event("voice.adapter.connecting", level: .info)
        let convo = await MainActor.run { () -> SDKConversation in
            SDKConversation(debug: false) { [self] session in
                session = makeConfiguredSession(bookContext: bookContext, language: language)
            }
        }
        lock.withLock { self.conversation = convo }
        let capturedProviderCallId = try await convo.connect(ephemeralKey: ephemeralKey)
        lock.withLock { self._providerCallId = capturedProviderCallId }
        // Never log the raw call ID value (spec: "Do not record ... OpenAI
        // call IDs in general logs") — presence/absence only.
        if capturedProviderCallId == nil {
            Log.event("voice.adapter.provider_call_id.missing", level: .warning)
        } else {
            Log.event("voice.adapter.provider_call_id.captured", level: .info)
        }
        // The SDK's `connect()` returns after the SDP exchange but BEFORE the
        // WebRTC data channel opens. Until the data channel opens `convo.status`
        // reports `.disconnected` (its initial value — the SDK only flips it to
        // `.connected` on `dataChannelDidChangeState(.open)`). Returning here
        // would make the session's status observer read `.disconnected`, treat
        // it as a lost connection, and reconnect — spawning a second overlapping
        // peer (the "two voices" echo) in an endless loop. Wait for the channel
        // to actually open so "connected" is honest.
        try await Self.waitUntilConnected { [convo] in
            await MainActor.run {
                if case .connected = convo.status { return true }
                return false
            }
        }
        Log.event("voice.adapter.connected", level: .info)

        Log.event("voice.adapter.session.wait", level: .info)
        let sessionSnapshot = try await Self.waitUntilConfiguredSession { [convo] in
            await MainActor.run { convo.session }
        }
        let entryCount = await MainActor.run { convo.entries.count }
        Log.event("voice.adapter.session.snapshot", level: .info, data: [
            "hasSession": String(true),
            "entryCount": String(entryCount),
            "toolCount": String(sessionSnapshot.tools?.count ?? 0),
            "hasBookTool": String(Self.sessionHasBookContext(sessionSnapshot)),
            "toolChoice": String(describing: sessionSnapshot.toolChoice),
            "instructionsBytes": String(sessionSnapshot.instructions.utf8.count),
            "instructionsHasBookContext": String(sessionSnapshot.instructions.contains("bookContext")),
        ])

        // Permit WebRTC to (re)initialize the VoIP audio unit now that the peer
        // is connected. In manual mode this is what actually starts mic capture
        // + playout — and it re-runs on EVERY connect, fixing dead-audio on
        // session 2+. The AVAudioSession is already active here (the session
        // calls coordinator.requestActiveMode(.voice) before client.connect()).
        audioUnit.enableAudioUnit()
        startPumps(for: convo)
    }

    /// Polls `isConnected` until it returns true or `timeout` elapses, throwing
    /// `RealtimeClientError(code: "connect_timeout")` on timeout. Factored out
    /// of `connect()` (and `static` + closure-driven) so the white-box test can
    /// exercise the wait without a live WebRTC peer.
    static func waitUntilConnected(
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(100),
        isConnected: @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await isConnected() { return }
            try await Task.sleep(for: pollInterval)
        }
        if await isConnected() { return }
        throw RealtimeClientError(
            code: "connect_timeout",
            message: "WebRTC data channel did not open within \(timeout)"
        )
    }

    /// Cancels the active pumps and tears down the current `Conversation`,
    /// closing the WebRTC peer. Does NOT touch the stream continuations, so a
    /// reconnect can keep the same transcript/tool/error streams alive.
    /// `internal` for white-box testing (mirrors `isArgumentsReady`).
    ///
    /// We can NOT rely on `Conversation.deinit` to close the peer: the SDK's
    /// detached event-handling task strongly retains the `Conversation` while
    /// awaiting `client.events`, and that stream only finishes once the peer
    /// closes — a retain cycle that keeps the peer (and its audio) alive even
    /// after we drop our reference. So we explicitly call the vendored
    /// `Conversation.disconnect()` (cancel task + close peer + finish streams)
    /// on the main actor before niling.
    internal func teardownActiveConversation() async {
        pump.cancel()
        let convo: SDKConversation? = lock.withLock { self.conversation }
        if let convo {
            await MainActor.run { convo.disconnect() }
        }
        lock.withLock {
            self.conversation = nil
            self._providerCallId = nil
        }
    }

    public func disconnect() async {
        // Pump + Conversation teardown is the shared single-peer path.
        await teardownActiveConversation()

        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
        pump.reset()
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()

        // Stop + uninitialize WebRTC's VoIP audio unit on FULL session end so the
        // next session's connect() forces a clean re-init. Deliberately NOT done
        // in teardownActiveConversation() — that helper also runs at the top of
        // connect() on the in-session RECONNECT path, where disabling audio would
        // kill a live reconnect. Only full disconnect() flips it false. The
        // AVAudioSession is still active here (the session calls
        // coordinator.releaseActiveMode(.voice) AFTER client.disconnect()).
        audioUnit.disableAudioUnit()

        Log.event("voice.adapter.disconnected", level: .info)
    }

    public func currentStatus() async -> RealtimeConnectionStatus {
        let convo: SDKConversation? = lock.withLock { self.conversation }
        guard let convo else { return .disconnected }
        // SDK's status enum: .connected | .connecting | .disconnected (no
        // .disconnecting). Read on the main actor since Conversation is
        // @MainActor isolated.
        let raw = await MainActor.run { convo.status }
        switch raw {
        case .connected:    return .connected
        case .connecting:   return .connecting
        case .disconnected: return .disconnected
        }
    }

    public func errorStream() -> AsyncStream<RealtimeClientError> {
        AsyncStream { continuation in
            lock.withLock { errorContinuation = continuation }
        }
    }

    public func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            lock.withLock { transcriptContinuation = continuation }
        }
    }

    public func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
        AsyncStream { continuation in
            lock.withLock { toolCallContinuation = continuation }
            Log.event("voice.adapter.tool.stream.opened", level: .info)
        }
    }

    public func sendToolResult(callId: String, payload: String) async throws {
        let convo: SDKConversation? = lock.withLock { self.conversation }
        guard let convo else {
            Log.event("voice.adapter.tool.result.dropped", level: .error, data: [
                "callId": callId,
                "reason": "not_connected",
            ])
            throw RealtimeClientError(
                code: "not_connected",
                message: "Cannot send tool result: not connected"
            )
        }
        Log.event("voice.adapter.tool.result.forwarding", level: .info, data: [
            "callId": callId,
            "payloadBytes": String(payload.utf8.count),
        ])
        try await toolDispatcher.sendResult(callId: callId, payload: payload, on: convo)
    }

    // MARK: - Internal pumps

    /// Start the SDK→stream polling pumps for the connected `Conversation`.
    /// Delegates to `RealtimeEventPump`, passing lock-guarded accessors so each
    /// yield reads the adapter's CURRENT continuation under the adapter's lock —
    /// identical to the prior inline pump code.
    private func startPumps(for convo: SDKConversation) {
        pump.start(
            for: convo,
            errorContinuation: { [weak self] in
                self?.lock.withLock { self?.errorContinuation }
            },
            transcriptContinuation: { [weak self] in
                self?.lock.withLock { self?.transcriptContinuation }
            },
            toolCallContinuation: { [weak self] in
                self?.lock.withLock { self?.toolCallContinuation }
            }
        )
    }

    private static func sessionHasBookContext(_ session: SDKSession) -> Bool {
        session.toolChoice == .auto
            && session.instructions.contains("bookContext")
            && session.tools?.contains { tool in
                guard case let .function(function) = tool else { return false }
                return function.name == "bookContext"
            } == true
    }
}
