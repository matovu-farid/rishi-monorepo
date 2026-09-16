@testable import rishi
import Foundation



/// Test fake conforming to `RealtimeClientAPI`. Records connect/disconnect
/// calls and lets the test drive transcript + error events into the streams.
///
/// Plan 10-03's `RealtimeVoiceSession` actor tests construct this fake,
/// inject events, and verify the actor's reaction (status transitions,
/// MessageStore writes, error surfacing). No WebRTC, no SDK, no network.
///
/// `@unchecked Sendable` + `NSLock`: AsyncStream continuations are not Sendable
/// across actor hops in Swift 6 strict concurrency, so we manage them under
/// a non-async lock. All call counts are also lock-guarded.
public final class FakeRealtimeClient: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _status: RealtimeConnectionStatus = .disconnected
    private var _statusScript: [RealtimeConnectionStatus] = []
    private var _connectCalls: [String] = []   // ephemeral keys received, in order
    private var _connectBookContexts: [BookContextSnapshot?] = []
    private var _connectLanguages: [String?] = []
    private var _disconnectCalls = 0
    private var _providerCallId: String?
    private var _connectShouldThrow: Error?

    private var _failAllConnectsWith: Error?
    private var _connectDeferMicCapture: [Bool] = []
    private var _micCaptureEnabledCalls: [Bool] = []
    private var _assistantOutputEnabledCalls: [Bool] = []
    private var _cancelCurrentResponseCalls = 0
    private var _injectedAudio: [Data] = []
    private var _injectedText: [String] = []
    private var _injectAudioAcceptance: HandoffAcceptance = .accepted(path: .path0A)
    private var _injectTextAcceptance: HandoffAcceptance = .accepted(path: .path0C)

    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?

    // Tool-call surface (Plan 25-07): inject(toolCall:), sendToolResult, accessor.
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?
    private var pendingToolCalls: [RealtimeToolCallEvent] = []
    private var sentToolResults: [(callId: String, payload: String)] = []
    private var sendToolResultError: RealtimeClientError?

    public init() {}

    // MARK: - Test inspection

    /// Ephemeral keys passed to `connect(ephemeralKey:)`, in call order.
    public var connectCalls: [String] {
        lock.withLock { _connectCalls }
    }

    /// Book-context snapshots passed to `connect(ephemeralKey:bookContext:language:)`,
    /// in call order.
    public var connectBookContexts: [BookContextSnapshot?] {
        lock.withLock { _connectBookContexts }
    }

    /// Languages passed to `connect(ephemeralKey:bookContext:language:)`, in
    /// call order.
    public var connectLanguages: [String?] {
        lock.withLock { _connectLanguages }
    }

    /// `deferMicCapture` flags passed to `connect`, in call order.
    public var connectDeferMicCapture: [Bool] {
        lock.withLock { _connectDeferMicCapture }
    }

    /// `setMicCaptureEnabled` calls in order.
    public var micCaptureEnabledCalls: [Bool] {
        lock.withLock { _micCaptureEnabledCalls }
    }

    /// PCM payloads passed to `injectBufferedInputAudio`, in order.
    public var injectedAudio: [Data] {
        lock.withLock { _injectedAudio }
    }

    /// Text payloads passed to `injectBufferedInputText`, in order.
    public var injectedText: [String] {
        lock.withLock { _injectedText }
    }

    /// Configurable acceptance for inject calls in tests.
    public func setInjectAudioAcceptance(_ acceptance: HandoffAcceptance) {
        lock.withLock { _injectAudioAcceptance = acceptance }
    }

    public func setInjectTextAcceptance(_ acceptance: HandoffAcceptance) {
        lock.withLock { _injectTextAcceptance = acceptance }
    }

    public var assistantOutputEnabledCalls: [Bool] {
        lock.withLock { _assistantOutputEnabledCalls }
    }

    public var cancelCurrentResponseCalls: Int {
        lock.withLock { _cancelCurrentResponseCalls }
    }

    /// Number of times `disconnect()` was called.
    public var disconnectCalls: Int {
        lock.withLock { _disconnectCalls }
    }

    // MARK: - Test drivers

    /// Cause the next `connect()` call to throw `error`. Cleared after one use.
    public func failNextConnect(with error: Error) {
        lock.withLock { _connectShouldThrow = error }
    }

    /// Cause every subsequent `connect()` call to throw `error` until
    /// `clearAllConnectFailures()` is invoked. Used by reconnect-ladder
    /// tests that need a persistent failure mode rather than a one-shot.
    public func failAllConnects(with error: Error) {
        lock.withLock { _failAllConnectsWith = error }
    }

    /// Clear the "fail all connects" mode.
    public func clearAllConnectFailures() {
        lock.withLock { _failAllConnectsWith = nil }
    }

    /// Drive the value `providerCallId` returns. Defaults to `nil` (the
    /// "missing Location header" / not-yet-connected case) so tests must
    /// opt in to simulating a successful capture.
    public func setProviderCallId(_ callId: String?) {
        lock.withLock { _providerCallId = callId }
    }

    /// Drive a transcript event through the fake's stream. No-op if no
    /// transcript stream has been requested yet.
    public func inject(transcript event: RealtimeTranscriptEvent) {
        let continuation: AsyncStream<RealtimeTranscriptEvent>.Continuation? =
            lock.withLock { transcriptContinuation }
        continuation?.yield(event)
    }

    /// Drive a server error through the fake's stream. No-op if no error
    /// stream has been requested yet.
    public func inject(error: RealtimeClientError) {
        let continuation: AsyncStream<RealtimeClientError>.Continuation? =
            lock.withLock { errorContinuation }
        continuation?.yield(error)
    }

    /// Force the status snapshot to a new value (does NOT auto-yield events).
    public func setStatus(_ status: RealtimeConnectionStatus) {
        lock.withLock { _status = status }
    }

    /// Queue a deterministic sequence of statuses returned by successive
    /// `currentStatus()` calls (one popped per call; the queue's last value
    /// then sticks). Lets reconnect tests model a transient `.disconnected`
    /// blip vs. a sustained drop without racing real timers. Each popped value
    /// also becomes the new sticky `_status`.
    public func scriptStatuses(_ statuses: [RealtimeConnectionStatus]) {
        lock.withLock { _statusScript = statuses }
    }

    // MARK: - Tool-call test drivers (Plan 25-07)

    /// Drive a tool-call event through the fake's stream. If no consumer has
    /// requested `toolCallStream()` yet, the event is queued and replayed when
    /// the stream is opened. Mirrors the existing `inject(transcript:)` shape
    /// except for the replay-on-subscribe semantics (Responder unit tests in
    /// Plan 25-09 may call `inject(toolCall:)` before subscribing).
    public func inject(toolCall event: RealtimeToolCallEvent) {
        lock.withLock {
            if let cont = self.toolCallContinuation {
                cont.yield(event)
            } else {
                self.pendingToolCalls.append(event)
            }
        }
    }

    /// Snapshot of every `(callId, payload)` pair recorded by `sendToolResult`,
    /// in call order. Used by Plan 25-12 integration tests to assert the
    /// Responder wrote the expected payload back.
    public func sentToolResultsSnapshot() -> [(callId: String, payload: String)] {
        lock.withLock { sentToolResults }
    }

    /// Stage a one-shot error for the next `sendToolResult(...)` call. Cleared
    /// after the throw. Subsequent `sendToolResult` calls succeed normally.
    public func setSendToolResultError(_ error: RealtimeClientError?) {
        lock.withLock { sendToolResultError = error }
    }

    // MARK: - RealtimeClientAPI

    public func connect(
        ephemeralKey: String,
        bookContext: BookContextSnapshot?,
        language: String?,
        deferMicCapture: Bool
    ) async throws {
        let throwError: Error? = lock.withLock {
            // One-shot failure wins over fail-all, then is cleared.
            let oneShot = _connectShouldThrow
            _connectShouldThrow = nil
            _connectCalls.append(ephemeralKey)
            _connectBookContexts.append(bookContext)
            _connectLanguages.append(language)
            _connectDeferMicCapture.append(deferMicCapture)
            return oneShot ?? _failAllConnectsWith
        }
        if let throwError { throw throwError }
        lock.withLock { _status = .connected }
    }

    public func setMicCaptureEnabled(_ enabled: Bool) async {
        lock.withLock { _micCaptureEnabledCalls.append(enabled) }
    }

    public func setAssistantOutputEnabled(_ enabled: Bool) async {
        lock.withLock { _assistantOutputEnabledCalls.append(enabled) }
    }

    public func cancelCurrentResponse() async {
        lock.withLock { _cancelCurrentResponseCalls += 1 }
    }

    public func injectBufferedInputAudio(_ pcm16le24kMono: Data) async throws -> HandoffAcceptance {
        let (isConnected, acceptance) = lock.withLock {
            _injectedAudio.append(pcm16le24kMono)
            return (_status == .connected, _injectAudioAcceptance)
        }
        guard isConnected else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "FakeRealtimeClient: not connected"
            )
        }
        return acceptance
    }

    public func injectBufferedInputText(_ text: String) async throws -> HandoffAcceptance {
        let (isConnected, acceptance) = lock.withLock {
            _injectedText.append(text)
            return (_status == .connected, _injectTextAcceptance)
        }
        guard isConnected else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "FakeRealtimeClient: not connected"
            )
        }
        return acceptance
    }

    public func disconnect() async {
        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            _disconnectCalls += 1
            _status = .disconnected
            _providerCallId = nil
            _connectDeferMicCapture = []
            _micCaptureEnabledCalls = []
            _injectedAudio = []
            _injectedText = []
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()
    }

    public func currentStatus() async -> RealtimeConnectionStatus {
        lock.withLock {
            if _statusScript.isEmpty { return _status }
            let next = _statusScript.removeFirst()
            _status = next
            return next
        }
    }

    public var providerCallId: String? {
        lock.withLock { _providerCallId }
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
                self.toolCallContinuation = continuation
                // Replay any tool calls injected before this subscribe — keeps
                // the Plan 25-09 Responder unit tests order-independent.
                for pending in self.pendingToolCalls {
                    continuation.yield(pending)
                }
                self.pendingToolCalls = []
            }
        }
    }

    public func sendToolResult(callId: String, payload: String) async throws {
        let (isConnected, stagedError): (Bool, RealtimeClientError?) = lock.withLock {
            (self._status == .connected, self.sendToolResultError)
        }
        guard isConnected else {
            throw RealtimeClientError(
                code: "not_connected",
                message: "FakeRealtimeClient: not connected"
            )
        }
        if let stagedError {
            lock.withLock { self.sendToolResultError = nil }
            throw stagedError
        }
        lock.withLock {
            self.sentToolResults.append((callId: callId, payload: payload))
        }
    }
}
