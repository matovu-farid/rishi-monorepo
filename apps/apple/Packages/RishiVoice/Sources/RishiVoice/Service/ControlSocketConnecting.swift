import Foundation

/// Seam isolating `RealtimeVoiceSession` from the concrete
/// `ControlWebSocketClient` actor (landed by the "voice-control-websocket-
/// client" plan, same package). Mirrors that type's real public surface
/// exactly — see this task's prerequisite note for the source of truth.
/// `RealtimeVoiceSession` never touches WebSocket transport, framing, or
/// reconnect/backoff logic directly.
///
/// Deliberately does NOT declare `onTerminal` as a protocol requirement:
/// `ControlWebSocketClient` takes it as an `init` parameter, not a method,
/// so the termination callback is supplied by whoever constructs the
/// concrete instance (see `RealtimeVoiceSession.controlSocketFactory` in
/// Task 11 and `VoiceSessionPresenter` in Task 12) rather than through this
/// protocol's method surface.
public protocol ControlSocketConnecting: Sendable {
    /// General message stream (allowance updates, ending warning, advisory
    /// errors, snapshots). Do NOT use this to detect session termination —
    /// see `ControlTerminalSignal`'s doc comment; termination is delivered
    /// exclusively through the `onTerminal` callback passed at construction.
    var messages: AsyncStream<ControlMessage> { get }

    /// Opens the WebSocket. Call once, after the Rishi voice session already
    /// exists server-side (i.e. after `POST /api/voice-sessions/:id/register-call`
    /// succeeds — see `RealtimeVoiceSession.startTrialVoiceSession`).
    func connect() async

    /// Forces an immediate reconnect attempt outside the current backoff
    /// delay. Not called anywhere in this plan (reconnect is automatic and
    /// internal) — exposed for a future app-foreground hook.
    func reconnect() async

    /// Graceful, caller-initiated close. Idempotent, safe to call even
    /// after the terminal callback already fired.
    func disconnect() async

    /// Sends the advisory `client_ack`. Never required by this plan; kept
    /// on the seam for parity with the concrete type's full surface.
    func sendClientAck() async

    /// Sends `{type:"client_activity"}` to refresh server-side
    /// `lastActivityAt` for inactivity timeout. Call on user and assistant
    /// transcript progress (partial or final). Must not be used from
    /// `disconnect()` / teardown.
    func sendClientActivity() async
}
