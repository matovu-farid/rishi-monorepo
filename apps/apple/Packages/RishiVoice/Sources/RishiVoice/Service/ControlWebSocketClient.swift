import Foundation
import RishiCore
import RishiLogging

/// Delivered exactly once via `ControlWebSocketClient`'s `onTerminal`
/// callback when the control channel reports the voice session has ended.
/// Carries the reason so the caller (the voice-session-flow-wiring plan)
/// can route to the right UI without a second round of message-matching.
public struct ControlTerminalSignal: Sendable, Equatable {
    public let rishiSessionId: String
    public let reason: ControlTerminalReason

    public init(rishiSessionId: String, reason: ControlTerminalReason) {
        self.rishiSessionId = rishiSessionId
        self.reason = reason
    }
}

/// Wraps `URLSessionWebSocketTask` for the Worker's per-voice-session
/// control route (`GET /api/voice-sessions/{id}/control`). See
/// `docs/superpowers/plans/2026-07-17-voice-control-websocket-client.md`
/// ("Design decisions") for why this is an `actor`, why observation is
/// `AsyncStream` + a mandatory callback rather than `@Observable`, and why
/// reconnect is unbounded-attempts / capped-backoff rather than the
/// bounded ladder `ReconnectController` uses for the WebRTC transport.
///
/// One client owns exactly one Rishi voice session, matching the spec's
/// "authenticated WebSocket endpoint per Rishi voice session." Construct a
/// fresh instance per voice session; do not reuse one across sessions.
///
/// Lifecycle contract for callers:
/// 1. Construct with a required `onTerminal` callback.
/// 2. Call `connect()` once, after the voice session is created server-side.
/// 3. Observe `messages` for `allowance_remaining` / `session_ending` /
///    `session_error` UI updates. Do NOT rely on filtering `messages` to
///    catch termination — use `onTerminal`.
/// 4. Call `disconnect()` when the OWNING session ends for any reason this
///    client itself did not already detect (e.g. the user manually leaves
///    the voice screen). Safe to call even after `onTerminal` already
///    fired (no-op).
public actor ControlWebSocketClient: ControlSocketConnecting {

    // MARK: - Reconnect tuning

    /// 1s, 2s, 4s, 8s, 16s, then holds at a 30s ceiling. Same doubling
    /// shape as `RealtimeVoiceSession`'s default `backoff` closure, but
    /// with a ceiling instead of a hard `maxReconnects` cutoff — see this
    /// plan's "Design decisions" #3 for why this loop never gives up on
    /// its own.
    public static func defaultBackoff(attempt: Int) -> Duration {
        let clamped = max(1, min(attempt, 6))
        let seconds = min(30.0, pow(2.0, Double(clamped - 1)))
        return .seconds(seconds)
    }

    private static let clientAckJSON = #"{"type":"client_ack"}"#

    private let baseURL: URL
    private let tokenProvider: any TokenProvider
    private let rishiSessionId: String
    private let urlSession: URLSession
    private let backoff: @Sendable (Int) -> Duration
    private let onTerminal: @Sendable (ControlTerminalSignal) async -> Void

    public nonisolated let messages: AsyncStream<ControlMessage>
    private let continuation: AsyncStream<ControlMessage>.Continuation

    /// Bumped on every `attemptConnect()`. A receive loop captures its own
    /// generation and checks it before mutating shared state, so a stale
    /// loop from a superseded connection attempt (e.g. after `reconnect()`
    /// forced a fresh one) can never clobber a newer connection's state.
    private var generation = 0
    private var currentTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isIntentionalClose = false
    private var isTerminal = false

    /// Synchronous-read snapshot of the last decoded message (mirrors
    /// `EntitlementService.snapshot()`'s "read the cached value without an
    /// extra round trip" convenience). `nil` before the first message
    /// arrives, which is at most the time between `connect()` and the
    /// server's initial `snapshot` — normally sub-second.
    public private(set) var latestMessage: ControlMessage?

    public init(
        baseURL: URL,
        tokenProvider: any TokenProvider,
        rishiSessionId: String,
        urlSession: URLSession = .shared,
        backoff: @escaping @Sendable (Int) -> Duration = ControlWebSocketClient.defaultBackoff,
        onTerminal: @escaping @Sendable (ControlTerminalSignal) async -> Void
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.rishiSessionId = rishiSessionId
        self.urlSession = urlSession
        self.backoff = backoff
        self.onTerminal = onTerminal

        var continuation: AsyncStream<ControlMessage>.Continuation!
        self.messages = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    // MARK: - Public API

    /// Opens the control WebSocket. Call once, after the Worker has
    /// created the voice session (`POST /api/voice-sessions` per the
    /// spec's "Voice Chat flow" step 1-2) so the session already exists
    /// for the DO to validate against.
    public func connect() async {
        isIntentionalClose = false
        reconnectAttempt = 0
        await attemptConnect()
    }

    /// Forces an immediate reconnect attempt outside the current backoff
    /// delay — e.g. the app just returned to foreground. Cancels any
    /// pending scheduled retry first. No-op once a terminal message has
    /// already been observed (nothing left to reconnect to).
    public func reconnect() async {
        guard !isTerminal else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        isIntentionalClose = false
        await attemptConnect()
    }

    /// Graceful, caller-initiated close. Best-effort sends the advisory
    /// `client_ack` (its failure is ignored — see the spec: this message
    /// never affects server enforcement), then cancels the task with a
    /// normal closure code. Marks the close as intentional so the receive
    /// loop's resulting error does NOT schedule a reconnect. Idempotent —
    /// safe to call multiple times, including after a terminal signal
    /// already fired.
    public func disconnect() async {
        isIntentionalClose = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if let currentTask {
            try? await currentTask.send(.string(Self.clientAckJSON))
            currentTask.cancel(with: .normalClosure, reason: nil)
        }
        receiveTask?.cancel()
        receiveTask = nil
        currentTask = nil
    }

    /// Sends the advisory `client_ack` without closing the connection.
    /// Exists for a caller that wants to acknowledge a message (e.g. a
    /// `session_ending` warning) while staying connected. Never awaited by
    /// server logic — safe to fire-and-forget; failures are swallowed.
    public func sendClientAck() async {
        guard let currentTask else { return }
        try? await currentTask.send(.string(Self.clientAckJSON))
    }

    // MARK: - Connection

    private func attemptConnect() async {
        guard !isTerminal else { return }
        generation += 1
        let myGeneration = generation

        var request = URLRequest(url: controlURL())
        request.httpShouldHandleCookies = false
        if let token = await tokenProvider.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        Log.event("voice.control.connecting", level: .info, data: [
            "rishi_session_id": rishiSessionId,
            "attempt": String(reconnectAttempt),
        ])

        let task = urlSession.webSocketTask(with: request)
        currentTask = task
        task.resume()
        // KEEP: receive loop hops onto this actor via `await self?....`; the
        // Task itself is unstructured so it can outlive the connect call.
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop(task, generation: myGeneration)
        }
    }

    /// `baseURL` is the plain `https://` worker root (e.g.
    /// `https://api.fidexa.org`, per `ServiceGraphFactory`); this flips the
    /// scheme to `wss://` (or `ws://` for an `http://` dev base URL) and
    /// appends the control path for this client's session.
    private func controlURL() -> URL {
        var url = baseURL
        url.append(path: "/api/voice-sessions/\(rishiSessionId)/control")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        return components.url ?? url
    }

    private func runReceiveLoop(_ task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            do {
                let raw = try await task.receive()
                await handle(raw, generation: generation)
            } catch {
                break
            }
        }
        await handleDisconnected(generation: generation)
    }

    private func handle(_ raw: URLSessionWebSocketTask.Message, generation: Int) async {
        guard generation == self.generation else { return }

        let text: String
        switch raw {
        case .string(let s):
            text = s
        case .data(let d):
            text = String(decoding: d, as: UTF8.self)
        @unknown default:
            return
        }
        guard let data = text.data(using: .utf8) else { return }

        let message: ControlMessage
        do {
            message = try JSONDecoder().decode(ControlMessage.self, from: data)
        } catch {
            Log.event("voice.control.decode_failed", level: .warning, data: [
                "error": String(describing: error),
            ])
            return
        }

        latestMessage = message
        continuation.yield(message)
        // Any successfully decoded message proves this connection is
        // healthy — reset the backoff ladder so a LATER drop starts again
        // at the shortest delay rather than inheriting a stale attempt count.
        reconnectAttempt = 0

        if message.isTerminal {
            await markTerminal(message: message)
        }
    }

    private func markTerminal(message: ControlMessage) async {
        guard !isTerminal else { return }
        isTerminal = true
        reconnectTask?.cancel()
        reconnectTask = nil

        let reason: ControlTerminalReason
        switch message {
        case .sessionEnded(_, let r):
            reason = r
        case .snapshot(_, _, _, _, _, let r):
            reason = r ?? .unknown("missing_reason")
        case .allowanceRemaining, .sessionEnding, .sessionError:
            reason = .unknown("unexpected_terminal_source")
        }

        Log.event("voice.control.terminal", level: .info, data: [
            "rishi_session_id": message.rishiSessionId,
        ])
        await onTerminal(ControlTerminalSignal(rishiSessionId: message.rishiSessionId, reason: reason))

        continuation.finish()
        // No more work over this socket — close it ourselves rather than
        // waiting on a peer close we don't need.
        isIntentionalClose = true
        currentTask?.cancel(with: .normalClosure, reason: nil)
    }

    private func handleDisconnected(generation: Int) async {
        guard generation == self.generation else { return }
        currentTask = nil
        receiveTask = nil
        guard !isIntentionalClose, !isTerminal else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = backoff(attempt)
        Log.event("voice.control.reconnect_scheduled", level: .warning, data: [
            "rishi_session_id": rishiSessionId,
            "attempt": String(attempt),
        ])
        // KEEP: reconnect sleep then hops back onto this actor via
        // `await self?.attemptConnect()`; cancellation aborts the delay.
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptConnect()
        }
    }
}
