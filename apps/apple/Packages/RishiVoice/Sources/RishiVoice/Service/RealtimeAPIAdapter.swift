import Foundation
import RealtimeAPI
import RishiLogging

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
    private var conversation: Conversation?

    // Persistent stream continuations across the adapter's lifetime. New
    // consumers re-call to get a new stream backed by the same continuation
    // slot — finishing on `disconnect()`.
    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    // Internal collaborators — constructed here so the public `init()` is
    // unchanged. `let` (stateless / handle-holding); behavior identical.
    private let audioUnit = WebRTCAudioUnitController()
    private let configBuilder = RealtimeSessionConfigBuilder()
    private let toolDispatcher = RealtimeToolCallDispatcher()
    private let pump = RealtimeEventPump()

    public init() {}

    // MARK: - White-box test seams (preserved)
//    //
//    // These forward to the pump / config builder / dispatcher so the existing
//    // `@testable` tests (`RealtimeAPIAdapterTeardownTests`,
//    // `RealtimeAPIAdapterAudioFormatTests`, `RealtimeAPIAdapterToolCallTests`)
//    // keep pointing at the same symbols after the decomposition.
//
//    /// Test seam: the error pump handle now lives on `RealtimeEventPump`.
//    internal var errorPump: Task<Void, Never>? {
//        get { pump.errorPump }
//        set { pump.errorPump = newValue }
//    }
//    /// Test seam: the transcript pump handle now lives on `RealtimeEventPump`.
//    internal var transcriptPump: Task<Void, Never>? {
//        get { pump.transcriptPump }
//        set { pump.transcriptPump = newValue }
//    }
//    /// Test seam: the tool-call pump handle now lives on `RealtimeEventPump`.
//    internal var toolCallPump: Task<Void, Never>? {
//        get { pump.toolCallPump }
//        set { pump.toolCallPump = newValue }
//    }
//
//    /// Test seam: PCM 24kHz format (delegates to the config builder).
//    static func makePCM24kFormat() -> Session.AudioFormat {
//        RealtimeSessionConfigBuilder.makePCM24kFormat()
//    }
//
//    /// Test seam: per-platform input noise reduction (delegates to the builder).
//    static var inputNoiseReduction: Session.Audio.Input.NoiseReduction {
//        RealtimeSessionConfigBuilder.inputNoiseReduction
//    }
//
//    /// Test seam: tool-call readiness gate (delegates to the dispatcher).
//    internal func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
//        toolDispatcher.isArgumentsReady(fc: fc)
//    }

    // MARK: - RealtimeClientAPI

    public func connect(ephemeralKey: String) async throws {
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
        let convo = await MainActor.run { () -> Conversation in
            Conversation(debug: false) { [configBuilder] session in
                session.audio = configBuilder.makeSessionAudio()
            }
        }
        lock.withLock { self.conversation = convo }
        try await convo.connect(ephemeralKey: ephemeralKey)
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
        let convo: Conversation? = lock.withLock { self.conversation }
        if let convo {
            await MainActor.run { convo.disconnect() }
        }
        lock.withLock { self.conversation = nil }
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
        let convo: Conversation? = lock.withLock { self.conversation }
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
        }
    }

    public func sendToolResult(callId: String, payload: String) async throws {
        let convo: Conversation? = lock.withLock { self.conversation }
        guard let convo else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "Cannot send tool result: not connected"
            )
        }
        try await toolDispatcher.sendResult(callId: callId, payload: payload, on: convo)
    }

    // MARK: - Internal pumps

    /// Start the SDK→stream polling pumps for the connected `Conversation`.
    /// Delegates to `RealtimeEventPump`, passing lock-guarded accessors so each
    /// yield reads the adapter's CURRENT continuation under the adapter's lock —
    /// identical to the prior inline pump code.
    private func startPumps(for convo: Conversation) {
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
}
