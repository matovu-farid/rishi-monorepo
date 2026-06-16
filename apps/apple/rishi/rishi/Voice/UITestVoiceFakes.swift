//
//  UITestVoiceFakes.swift
//  rishi
//
//  DEBUG-only, RISHI_UITEST-gated fakes that let a voice session reach `.live`
//  fully offline (no worker, no OpenAI, no WebRTC). They exist so the
//  start -> end -> start voice reproduction UITest (VoiceRestartUITests) can
//  drive the real VoiceSessionPresenter / RealtimeVoiceSession FSM
//  deterministically. Everything here is gated behind BOTH `#if DEBUG` AND the
//  `RISHI_UITEST == "1"` launch environment variable (via
//  `UITestBypass.isActive`), so it can NEVER affect a TestFlight / App Store
//  build and NEVER runs in a normal launch.
//
//  The fakes mirror the unit-test `FakeRealtimeClient` shape (see
//  RishiVoiceTests/Fakes/FakeRealtimeClient.swift): an `@unchecked Sendable`
//  class managing AsyncStream continuations under an `NSLock`. The crucial
//  difference: this UI-test fake STAYS connected. It transitions
//  `disconnected -> connecting -> connected` on `connect()` (mimicking the
//  real connecting->connected transition so the FSM and the device logs
//  behave like prod), then holds `.connected` until `disconnect()`. It never
//  self-disconnects, so any teardown the UITest observes is the BUG, not the
//  fake dropping the session.
//

#if DEBUG
import Foundation
import RishiCore
import RishiAPI
import RishiVoice

/// Offline `RealtimeClientAPI` for UI tests. Reaches `.connected` after a
/// short async delay and stays there; streams are real AsyncStreams that stay
/// open until `disconnect()`. `sendToolResult` is a no-op. No network.
final class UITestFakeRealtimeClient: RealtimeClientAPI, @unchecked Sendable {

    private let lock = NSLock()
    private var _status: RealtimeConnectionStatus = .disconnected

    private var errorContinuation: AsyncStream<RealtimeClientError>.Continuation?
    private var transcriptContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var toolCallContinuation: AsyncStream<RealtimeToolCallEvent>.Continuation?

    init() {}

    func connect(ephemeralKey: String) async throws {
        // Mimic the real connecting -> connected transition so the FSM and the
        // status poll see the same shape they would in prod. A short delay
        // models the WebRTC negotiation without any actual network.
        lock.withLock { _status = .connecting }
        try? await Task.sleep(for: .milliseconds(120))
        lock.withLock { _status = .connected }
    }

    func disconnect() async {
        let (errCont, txCont, tcCont): (
            AsyncStream<RealtimeClientError>.Continuation?,
            AsyncStream<RealtimeTranscriptEvent>.Continuation?,
            AsyncStream<RealtimeToolCallEvent>.Continuation?
        ) = lock.withLock {
            _status = .disconnected
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
        errCont?.finish()
        txCont?.finish()
        tcCont?.finish()
    }

    func currentStatus() async -> RealtimeConnectionStatus {
        // STAYS connected once connected — the status poll in
        // RealtimeVoiceSession.startStatusObservation() must never read
        // `.disconnected` from the fake, or it would reconnect/fail on its own
        // and mask the actual bug.
        lock.withLock { _status }
    }

    func errorStream() -> AsyncStream<RealtimeClientError> {
        AsyncStream { continuation in
            lock.withLock { errorContinuation = continuation }
        }
    }

    func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            lock.withLock { transcriptContinuation = continuation }
        }
    }

    func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
        AsyncStream { continuation in
            lock.withLock { toolCallContinuation = continuation }
        }
    }

    func sendToolResult(callId: String, payload: String) async throws {
        // No-op offline — the UITest does not exercise the RAG tool round trip.
    }
}

/// Offline `EphemeralKeyFetching` for UI tests. Returns a canned key
/// immediately so the `start()` key-fetch step succeeds with no worker call.
struct UITestFakeEphemeralKeyFetcher: EphemeralKeyFetching {
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        EphemeralKey(secret: "uitest-fake-ephemeral-secret", sessionId: "uitest-fake-session")
    }
}

/// Always-granted mic gate for UI tests. The production `SystemMicPermissionGate`
/// would surface the OS record-permission dialog on a fresh simulator
/// (`.undetermined`), which would stall the headless UITest. Granting
/// unconditionally lets `RealtimeVoiceSession.start()` proceed straight to the
/// key fetch with no system prompt.
struct UITestGrantedMicGate: MicPermissionGate {
    func request() async -> MicPermissionDecision { .granted }
}
#endif
