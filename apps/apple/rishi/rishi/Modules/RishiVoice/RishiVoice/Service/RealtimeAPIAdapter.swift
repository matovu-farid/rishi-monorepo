import Foundation






typealias SDKConversation = RealtimeConversation
typealias SDKSession = RealtimeSession

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
    /// A disconnected Conversation whose peer/data-channel objects have been
    /// constructed ahead of the ephemeral-key request. `connect()` consumes
    /// this once for the initial connection; reconnects always get a fresh
    /// peer because WebRTC connections cannot be reused after teardown.
    private var prewarmTask: Task<SDKConversation, Never>?

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

    /// When false, handoff is in progress and assistant output should stay gated
    /// until live mic cutover (VoIP unit remains off until `setMicCaptureEnabled`).
    private var assistantOutputEnabled = true

    /// Bytes per 100 ms chunk at 24 kHz mono PCM16 (inject Path 0B fallback).
    private static let pcmAppendChunkBytes = 4_800
    /// OpenAI rejects `input_audio_buffer.commit` below 100 ms of PCM16 @ 24 kHz.
    private static let minInputAudioBufferCommitBytes = 4_800
    /// Path 0A (`conversation.item.create` + audio) — prefer under this size.
    private static let maxSendUserAudioBytes = 256 * 1024

    /// See the `_providerCallId` doc comment above for the full contract.
    public var providerCallId: String? {
        lock.withLock { _providerCallId }
    }

    public init() {}

    /// Pre-construct the local WebRTC peer while the Worker creates the
    /// Rishi/OpenAI session. This does not negotiate, open a data channel, or
    /// enable audio; it only moves expensive factory/track construction off
    /// the connection critical path. The task is shared so concurrent callers
    /// never create two peers.
    public func prewarm() async {
        Log.event("voice.adapter.prewarm.begin", level: .info)
        audioUnit.enableManualModeOnce()
        let task: Task<SDKConversation, Never>? = lock.withLock {
            guard conversation == nil else { return nil }
            if let prewarmTask { return prewarmTask }
            let task = Task { @MainActor in
                SDKConversation(debug: false)
            }
            prewarmTask = task
            return task
        }
        if let task {
            await withTaskCancellationHandler {
                _ = await task.value
                Log.event("voice.adapter.prewarm.completed", level: .info)
            } onCancel: {
                task.cancel()
                Log.event("voice.adapter.prewarm.cancelled", level: .warning)
            }
        }
    }

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
            instructions: ""
        )
        configBuilder.configure(session: &session, bookContext: bookContext, language: language)
        return session
    }

    /// Wait for the realtime session to become visible on the conversation and
    /// confirm that the expected book tool config landed. The prompt text is
    /// rendered by the Worker and can legitimately differ between clients;
    /// the tool definition is the stable readiness contract.
    static func waitUntilConfiguredSession(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(15),
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

    /// Event-driven counterpart to the legacy snapshot polling seam. The SDK
    /// buffers session updates, so this remains race-free even when the
    /// session-created/session-updated events arrive during `connect()`.
    static func waitUntilConfiguredSession(
        timeout: Duration = .seconds(5),
        sessionUpdates: AsyncStream<SDKSession>
    ) async throws -> SDKSession {
        try await withThrowingTaskGroup(of: SDKSession.self) { group in
            group.addTask {
                for await session in sessionUpdates {
                    if sessionHasBookContext(session) { return session }
                }
                throw RealtimeClientError(
                    code: "session_not_ready",
                    message: "Realtime session updates ended before configuration was observed"
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RealtimeClientError(
                    code: "session_not_ready",
                    message: "Realtime session never exposed the configured book tool and instructions"
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RealtimeClientError(
                    code: "session_not_ready",
                    message: "Realtime session readiness task ended without a result"
                )
            }
            return result
        }
    }

    internal func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
        toolDispatcher.isArgumentsReady(fc: fc)
    }

    // MARK: - RealtimeClientAPI

    public func connect(
        ephemeralKey: String,
        bookContext: BookContextSnapshot? = nil,
        language: String? = nil,
        deferMicCapture: Bool = false
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
        // A reconnect may carry a newer page/paragraph snapshot than the
        // ephemeral key was minted with. The first connection can trust the
        // server-minted configuration (and avoid `session.update`); only a
        // reconnect needs to re-apply the latest client context.
        let isReconnect = lock.withLock { conversation != nil }
        await teardownActiveConversation()
        Log.event("voice.adapter.connecting", level: .info, data: [
            "is_reconnect": String(isReconnect),
            "defer_mic_capture": String(deferMicCapture),
            "has_book_context": String(bookContext != nil),
        ])
        // The ephemeral client secret is minted with the complete session
        // configuration (prompt, tools, VAD, and audio formats) by the
        // Worker. Passing a session-update callback here would send the same
        // configuration again after `session.created`, forcing an additional
        // data-channel round trip before audio can flow. Keep the server's
        // configuration authoritative for the initial connection; reconnects
        // re-apply the latest page context above, while `sessionUpdates` below
        // validates that the resulting configuration arrived.
        // A prewarmed peer is valid only for the first connection. If this is
        // a reconnect, discard the pending task and construct a fresh peer —
        // WebRTC does not permit reusing a closed connection.
        let pendingPrewarm: Task<SDKConversation, Never>? = lock.withLock {
            let task = prewarmTask
            prewarmTask = nil
            return task
        }
        if isReconnect {
            pendingPrewarm?.cancel()
        }
        let convo: SDKConversation
        if !isReconnect, let pendingPrewarm {
            Log.event("voice.adapter.peer_source", level: .info, data: ["source": "prewarmed"])
            convo = await pendingPrewarm.value
        } else {
            Log.event("voice.adapter.peer_source", level: .info, data: ["source": "new"])
            convo = await MainActor.run { () -> SDKConversation in
                if isReconnect {
                    return SDKConversation(debug: false) { [self] session in
                        session = makeConfiguredSession(bookContext: bookContext, language: language)
                    }
                }
                return SDKConversation(debug: false)
            }
        }
        Log.event(
            isReconnect ? "voice.adapter.session.update.reconnect" : "voice.adapter.session.update.server_minted",
            level: .info
        )
        // Capture the SDK's buffered readiness streams before beginning the
        // handshake. The data channel and session events can arrive before
        // `Conversation.connect()` returns, so subscribing afterward would
        // reintroduce a race and force us back to polling snapshots.
        let statusUpdates = await MainActor.run { convo.statusUpdates }
        let sessionUpdates = await MainActor.run { convo.sessionUpdates }
        lock.withLock { self.conversation = convo }
        let capturedProviderCallId = try await convo.connect(
            ephemeralKey: ephemeralKey
        )
        Log.event("voice.adapter.sdk_connect.returned", level: .info, data: [
            "provider_call_id_present": String(capturedProviderCallId != nil),
            "sdk_status": String(describing: await MainActor.run { convo.status }),
        ])
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
        do {
            try await Self.waitUntilConnected(statusUpdates: statusUpdates)
        } catch {
            Log.event("voice.adapter.data_channel.wait_failed", level: .error, data: [
                "error": String(describing: error),
                "sdk_status": String(describing: await MainActor.run { convo.status }),
            ])
            throw error
        }
        Log.event("voice.adapter.connected", level: .info)

        // The initial ephemeral secret already contains the complete session
        // configuration. Waiting for `session.created` here adds avoidable
        // latency and can strand the UI in Connecting if a provider event is
        // delayed even though the data channel is usable. Reconnects still
        // wait for the updated snapshot because they intentionally refresh
        // page context through `session.update`.
        let sessionSnapshot: SDKSession?
        if isReconnect {
            Log.event("voice.adapter.session.wait.reconnect", level: .info)
            sessionSnapshot = try await Self.waitUntilConfiguredSession(sessionUpdates: sessionUpdates)
        } else {
            Log.event("voice.adapter.session.server_minted_no_wait", level: .info)
            sessionSnapshot = await MainActor.run { convo.session }
        }
        let entryCount = await MainActor.run { convo.entries.count }
        Log.event("voice.adapter.session.snapshot", level: .info, data: [
            "hasSession": String(sessionSnapshot != nil),
            "entryCount": String(entryCount),
            "toolCount": String(sessionSnapshot?.tools?.count ?? 0),
            "hasBookTool": String(sessionSnapshot.map(Self.sessionHasBookContext) ?? false),
            "toolChoice": String(describing: sessionSnapshot?.toolChoice),
            "instructionsBytes": String(sessionSnapshot?.instructions.utf8.count ?? 0),
            "instructionsHasBookContext": String(sessionSnapshot?.instructions.contains("bookContext") ?? false),
        ])

        // Activation handoff: keep the VoIP unit OFF until local AVAudioEngine
        // has stopped — dual capture (engine + LKRTCAudioSession) drops ICE.
        // Non-deferred connect (incl. reconnect) initializes audio here.
        if deferMicCapture {
            Log.event("voice.adapter.audio.setup.deferred", level: .info)
            await MainActor.run { convo.muted = true }
            assistantOutputEnabled = false
        } else {
            Log.event("voice.adapter.audio.setup.enabling", level: .info)
            audioUnit.enableAudioUnit()
            assistantOutputEnabled = true
        }
        startPumps(for: convo)
    }

    public func setAssistantOutputEnabled(_ enabled: Bool) async {
        assistantOutputEnabled = enabled
        audioUnit.setAudioEnabled(enabled)
    }

    public func setMicCaptureEnabled(_ enabled: Bool) async {
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else { return }

        if !enabled {
            await MainActor.run { convo.muted = true }
            return
        }

        // First VoIP init happens here for activation handoff — after the
        // activation recorder has stopped and the input route has settled.
        audioUnit.enableAudioUnit()
        await MainActor.run { convo.muted = false }
        assistantOutputEnabled = true
    }

    public func cancelCurrentResponse() async {
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else { return }

        await MainActor.run {
            guard case .connected = convo.status else { return }
            try? convo.send(event: .cancelResponse())
        }
    }

    public func injectBufferedInputAudio(_ pcm16le24kMono: Data) async throws -> HandoffAcceptance {
        guard !pcm16le24kMono.isEmpty else { return .noSpeech }
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "Cannot inject audio: not connected"
            )
        }

        if pcm16le24kMono.count <= Self.maxSendUserAudioBytes {
            try await MainActor.run {
                try Self.sendPath0A(pcm16le24kMono, on: convo)
            }
            return .accepted(path: .path0A)
        }

        if pcm16le24kMono.count >= Self.minInputAudioBufferCommitBytes {
            return try await injectPath0B(pcm16le24kMono, on: convo)
        }

        return .rejected(path: .path0A, code: "inject_audio_too_small")
    }

    public func injectBufferedInputText(_ text: String) async throws -> HandoffAcceptance {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noSpeech }
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "Cannot inject text: not connected"
            )
        }
        try await MainActor.run {
            try convo.send(from: .user, text: trimmed)
        }
        return .accepted(path: .path0C)
    }

    @MainActor
    private static func sendPath0A(_ pcm16le24kMono: Data, on convo: SDKConversation) throws {
        let itemId = "act_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try convo.send(event: .createConversationItem(after: nil, .message(Item.Message(
            id: itemId,
            role: .user,
            content: [.inputAudio(.init(audio: pcm16le24kMono))]
        ))))
        try convo.send(event: .createResponse(using: nil))
    }

    private func injectPath0B(
        _ pcm16le24kMono: Data,
        on convo: SDKConversation
    ) async throws -> HandoffAcceptance {
        try await MainActor.run {
            try Self.injectViaAudioBuffer(pcm16le24kMono, on: convo)
        }
        return .accepted(path: .path0B)
    }

    /// Path 0B: stream PCM into the server input buffer, then commit + respond.
    @MainActor
    private static func injectViaAudioBuffer(_ pcm16le24kMono: Data, on convo: SDKConversation) throws {
        guard pcm16le24kMono.count >= minInputAudioBufferCommitBytes else {
            throw RealtimeClientError(
                code: "inject_audio_too_small",
                message: "Cannot commit input audio buffer shorter than 100ms"
            )
        }
        try convo.send(event: .clearInputAudioBuffer())
        var offset = pcm16le24kMono.startIndex
        while offset < pcm16le24kMono.endIndex {
            let end = pcm16le24kMono.index(
                offset,
                offsetBy: pcmAppendChunkBytes,
                limitedBy: pcm16le24kMono.endIndex
            ) ?? pcm16le24kMono.endIndex
            try convo.send(audioDelta: Data(pcm16le24kMono[offset..<end]), commit: false)
            offset = end
        }
        try convo.send(event: .commitInputAudioBuffer())
        try convo.send(event: .createResponse(using: nil))
    }

    /// Polls `isConnected` until it returns true or `timeout` elapses, throwing
    /// `RealtimeClientError(code: "connect_timeout")` on timeout. Factored out
    /// of `connect()` (and `static` + closure-driven) so the white-box test can
    /// exercise the wait without a live WebRTC peer.
    static func waitUntilConnected(
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(25),
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

    /// Event-driven data-channel readiness wait. The connector emits the
    /// transition at the exact delegate callback, avoiding the old 25 ms
    /// polling loop and its extra actor hops.
    static func waitUntilConnected(
        timeout: Duration = .seconds(15),
        statusUpdates: AsyncStream<RealtimeAPI.Status>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await status in statusUpdates {
                    if status == .connected { return }
                    if status == .disconnected {
                        throw RealtimeClientError(
                            code: "connect_closed",
                            message: "WebRTC data channel closed before it became ready"
                        )
                    }
                }
                throw RealtimeClientError(
                    code: "connect_closed",
                    message: "WebRTC status updates ended before the data channel opened"
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RealtimeClientError(
                    code: "connect_timeout",
                    message: "WebRTC data channel did not open within \(timeout)"
                )
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
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

        let pendingPrewarm: Task<SDKConversation, Never>? = lock.withLock {
            let task = prewarmTask
            prewarmTask = nil
            return task
        }
        pendingPrewarm?.cancel()

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
            && session.tools?.contains { tool in
                guard case let .function(function) = tool else { return false }
                return function.name == "bookContext"
            } == true
    }
}
