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
    /// Invalidated whenever an external disconnect begins. A connect that has
    /// consumed a prewarm task may still be awaiting peer construction, so it
    /// must not install or report that peer after a newer disconnect.
    private var lifecycleGeneration = 0

    // Persistent stream continuations across the adapter's lifetime. New
    // consumers re-call to get a new stream backed by the same continuation
    // slot — finishing on `disconnect()`.
    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?
    /// Tool calls can be observed by the SDK before the session responder has
    /// subscribed. Retain them until the single shared continuation is opened.
    private var pendingToolCallEvents: [RealtimeToolCallEvent] = []
    private var toolCallGeneration = 0
    private var toolCallStreamClosed = false

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
    private let toolDispatcher = RealtimeToolCallDispatcher()
    private let pump = RealtimeEventPump()

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

    public func cancelPrewarm() async {
        let task: Task<SDKConversation, Never>? = lock.withLock {
            let task = prewarmTask
            prewarmTask = nil
            return task
        }
        task?.cancel()
        if let task {
            let conversation = await task.value
            await MainActor.run { conversation.disconnect() }
        }
        if task != nil {
            Log.event("voice.adapter.prewarm.cancelled", level: .info)
        }
    }

    // MARK: - White-box test seams

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

    internal func isArgumentsReady(fc: Item.FunctionCall) -> Bool {
        toolDispatcher.isArgumentsReady(fc: fc)
    }

    internal func emitToolCallForTesting(
        _ event: RealtimeToolCallEvent,
        generation: Int? = nil
    ) {
        yieldToolCallEvent(event, generation: generation)
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
        // A reconnect may carry a newer page snapshot than the ephemeral key
        // was minted with. The SDK update below applies the current
        // Apple-side tool and instructions in both cases.
        let (connectGeneration, isReconnect) = lock.withLock {
            (lifecycleGeneration, conversation != nil)
        }
        await teardownActiveConversation()
        Log.event("voice.adapter.connecting", level: .info, data: [
            "is_reconnect": String(isReconnect),
            "defer_mic_capture_ignored": String(deferMicCapture),
            "has_book_context": String(bookContext != nil),
        ])
        // The Worker supplies server-owned audio/VAD/voice defaults. The SDK
        // update below starts from that session and changes only the fields
        // owned by this client.
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
            convo = await MainActor.run { SDKConversation(debug: false) }
        }
        // Capture the SDK's buffered readiness streams before beginning the
        // handshake. The data channel and session events can arrive before
        // `Conversation.connect()` returns, so subscribing afterward would
        // reintroduce a race and force us back to polling snapshots.
        let statusUpdates = await MainActor.run { convo.statusUpdates }
        let installed = lock.withLock { () -> Bool in
            guard lifecycleGeneration == connectGeneration else { return false }
            self.conversation = convo
            self.toolCallGeneration += 1
            // Pending events belong to the conversation generation that
            // produced them. Never replay an old generation into this one.
            self.pendingToolCallEvents.removeAll(keepingCapacity: true)
            self.toolCallStreamClosed = false
            return true
        }
        guard installed else {
            await MainActor.run { convo.disconnect() }
            throw RealtimeClientError(
                code: "connect_cancelled",
                message: "Realtime connection was cancelled before startup completed"
            )
        }
        let conversationGeneration = lock.withLock { self.toolCallGeneration }
        do {
            let capturedProviderCallId = try await convo.connect(
                ephemeralKey: ephemeralKey
            )
            Log.event("voice.adapter.sdk_connect.returned", level: .info, data: [
                "provider_call_id_present": String(capturedProviderCallId != nil),
                "sdk_status": String(describing: await MainActor.run { convo.status }),
            ])
            lock.withLock {
                guard self.conversation === convo,
                      self.toolCallGeneration == conversationGeneration else { return }
                self._providerCallId = capturedProviderCallId
            }
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
            try await Self.waitUntilConnected(statusUpdates: statusUpdates)
        } catch {
            Log.event("voice.adapter.data_channel.wait_failed", level: .error, data: [
                "error": String(describing: error),
                "sdk_status": String(describing: await MainActor.run { convo.status }),
            ])
            // Every failure after installing `conversation` owns a peer that
            // must be disconnected before the error escapes. The generation
            // guard prevents an older failed connect from tearing down a newer
            // session that won the lifecycle race.
            await teardownActiveConversation(expectedGeneration: conversationGeneration)
            throw error
        }
        Log.event("voice.adapter.connected", level: .info)

        // The SDK owns the session configuration and default WebRTC audio
        // lifecycle. Apple does not send a session.update or manually toggle
        // the WebRTC audio unit here.
        guard lock.withLock({
            self.conversation === convo && self.toolCallGeneration == conversationGeneration
        }) else {
            await MainActor.run { convo.disconnect() }
            throw RealtimeClientError(
                code: "connect_cancelled",
                message: "Realtime connection ended during startup"
            )
        }
        startPumps(for: convo, generation: conversationGeneration)
    }

    public func setMicCaptureEnabled(_ enabled: Bool) async {
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else { return }

        if !enabled {
            await MainActor.run { convo.muted = true }
            return
        }

        await MainActor.run { convo.muted = false }
    }

    public func cancelCurrentResponse() async {
        let convo: SDKConversation? = lock.withLock { conversation }
        guard let convo else { return }

        await MainActor.run {
            guard case .connected = convo.status else { return }
            // OpenAI requires these WebRTC events in this order. The cancel
            // stops generation; the buffer-clear cuts off audio already
            // queued for playout. Keep both sends in one synchronous block so
            // disconnect cannot race between them.
            try? convo.send(event: .cancelResponse())
            try? convo.send(event: .outputAudioBufferClear())
        }
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
    @discardableResult
    internal func teardownActiveConversation(expectedGeneration: Int? = nil) async -> Bool {
        let teardown: (conversation: SDKConversation?, generation: Int, matched: Bool) = lock.withLock {
            if let expectedGeneration,
               self.toolCallGeneration != expectedGeneration {
                return (nil, 0, false)
            }
            let generation = self.toolCallGeneration
            self.toolCallGeneration += 1
            self.pendingToolCallEvents.removeAll(keepingCapacity: true)
            // Serialize cancellation with conversation installation. A
            // reconnect cannot publish new pumps while this invalidation is
            // holding the adapter lock.
            self.pump.cancel()
            return (self.conversation, generation, true)
        }
        guard teardown.matched else {
            return false
        }
        let convo = teardown.conversation
        if let convo {
            await MainActor.run { convo.disconnect() }
        }
        let cleared = lock.withLock { () -> Bool in
            // Disconnect is awaited, so a newer connect may have installed a
            // different conversation while the old SDK peer was closing.
            // Only the owner of this teardown may clear adapter state.
            guard self.toolCallGeneration == teardown.generation + 1,
                  self.conversation === convo else { return false }
            self.conversation = nil
            self._providerCallId = nil
            return true
        }
        return cleared
    }

    public func disconnect() async {
        lock.withLock { lifecycleGeneration += 1 }
        // Clear a prewarm-only adapter before tearing down the active peer.
        // This path must not depend on `conversation` being non-nil: a user
        // can leave the guided reader while peer construction is still in
        // flight.
        await cancelPrewarm()
        // Pump + Conversation teardown is the shared single-peer path.
        _ = await teardownActiveConversation()

        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            toolCallStreamClosed = true
            pendingToolCallEvents.removeAll(keepingCapacity: false)
            return (e, t, tc)
        }
        pump.reset()
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()

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
            lock.withLock {
                toolCallStreamClosed = false
                toolCallContinuation = continuation
                // Replay while holding the same lock used by live delivery.
                // Buffered and live events therefore form one FIFO sequence.
                for event in pendingToolCallEvents {
                    continuation.yield(event)
                }
                pendingToolCallEvents.removeAll(keepingCapacity: true)
            }
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
    private func startPumps(for convo: SDKConversation, generation: Int) {
        lock.withLock {
            guard self.conversation === convo,
                  self.toolCallGeneration == generation else { return }
            pump.start(
                for: convo,
                errorContinuation: { [weak self] event in
                    self?.yieldErrorEvent(event, generation: generation)
                },
                transcriptContinuation: { [weak self] event in
                    self?.yieldTranscriptEvent(event, generation: generation)
                },
                toolCallContinuation: { [weak self] event in
                    self?.yieldToolCallEvent(event, generation: generation)
                }
            )
        }
    }

    internal var eventGeneration: Int {
        lock.withLock { toolCallGeneration }
    }

    internal func emitErrorForTesting(_ event: RealtimeClientError, generation: Int) {
        yieldErrorEvent(event, generation: generation)
    }

    internal func emitTranscriptForTesting(_ event: RealtimeTranscriptEvent, generation: Int) {
        yieldTranscriptEvent(event, generation: generation)
    }

    private func yieldErrorEvent(_ event: RealtimeClientError, generation: Int) {
        lock.withLock {
            guard generation == toolCallGeneration else { return }
            errorContinuation?.yield(event)
        }
    }

    private func yieldTranscriptEvent(_ event: RealtimeTranscriptEvent, generation: Int) {
        lock.withLock {
            guard generation == toolCallGeneration else { return }
            transcriptContinuation?.yield(event)
        }
    }

    private func yieldToolCallEvent(_ event: RealtimeToolCallEvent, generation: Int? = nil) {
        lock.withLock {
            if let generation, generation != toolCallGeneration { return }
            if toolCallStreamClosed { return }
            if let toolCallContinuation {
                toolCallContinuation.yield(event)
            } else {
                pendingToolCallEvents.append(event)
            }
        }
    }

}
