# Voice control WebSocket client (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **TDD override:** This plan intentionally skips writing tests and test-first steps. That is an explicit, one-time override of the writing-plans skill's TDD requirement for this plan only (matching the same override already used by `docs/superpowers/plans/2026-07-17-voice-control-websocket.md`, the Worker-side sibling plan). Every step is verified by running `swift test --package-path apps/apple/Packages/RishiVoice` (per `apps/apple/CLAUDE.md`, "Build-clean is a precondition") and checking that it compiles — never by a test assertion. Automated test coverage for this control-channel client is deferred to a later pass (see `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`, "Verification").

**Goal:** Add an iOS `ControlWebSocketClient` in the `RishiVoice` package that connects to the Worker's per-voice-session control WebSocket (`GET /api/voice-sessions/{id}/control`), decodes the server's typed messages, reconnects automatically with bounded backoff while a session is active, and gives the caller (the not-yet-written voice-session-flow-wiring plan) an unmissable terminal-state signal it can use to stop the local microphone and voice UI.

**Architecture:** `ControlWebSocketClient` is a new `actor` in `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/`, sitting next to `EphemeralKeyFetcher` and `ReconnectController` (same package, same layer: a networking/session-support service, not UI). It owns exactly one `URLSessionWebSocketTask` for exactly one Rishi voice session, matching the spec's "one control WebSocket per Rishi voice session." It builds the upgrade `URLRequest` itself (base worker URL + `/api/voice-sessions/{id}/control`, scheme flipped `https`→`wss`/`http`→`ws`) and sets a plain `Authorization: Bearer <token>` header via the existing `RishiCore.TokenProvider` protocol — the same seam `WorkerClient` already uses, so this plan needs no new auth plumbing. It does **not** route through `WorkerClient`, because `WorkerClient` has no WebSocket-upgrade method; this is the same reason the vendored `swift-realtime-openai` package builds its own `URLSessionWebSocketTask` directly from a `URLRequest` rather than going through a shared HTTP client. Decoded server messages surface two ways, deliberately combining two conventions that already coexist in this codebase for two different needs: a continuous `AsyncStream<ControlMessage>` (the same shape as `RishiBilling`'s `EntitlementService.currentLevel`) for general observation, and a mandatory, exactly-once `onTerminal` callback (the same shape as `ReconnectController.Callbacks`, this package) for the one signal that must never be missed. Reconnect is automatic and internal (an unbounded-attempt, capped-backoff loop, mirroring `ReconnectController`'s ladder shape but never giving up, since losing this control channel temporarily does not end the underlying OpenAI WebRTC audio) with a `reconnect()` escape hatch the caller can use to force an immediate retry (e.g. on app foreground). This plan does not touch session-active tracking, microphone teardown, or UI — those stay in the voice-session-flow-wiring plan, which is downstream of this one.

**Tech Stack:** `URLSessionWebSocketTask` (Foundation), Swift 6 strict concurrency (`actor` isolation — this package has no MainActor default, per `apps/apple/docs/SWIFT-CONCURRENCY-RULES.md`), `AsyncStream`, `RishiCore.TokenProvider`, `RishiLogging.Log`, Swift Testing conventions (no new tests added by this plan; existing package test suite must keep compiling).

---

## Prerequisite / cross-plan contract

This plan consumes the **already-landed** Worker contract from `docs/superpowers/plans/2026-07-17-voice-control-websocket.md`, "Exports for downstream plans" (verbatim, do not re-derive):

- **Route:** `GET /api/voice-sessions/{rishiSessionId}/control` — WebSocket upgrade. A non-upgrade request gets `426`.
- **Auth:** standard `Authorization: Bearer <accessToken>` header on the upgrade request itself.
- **Server → client JSON shapes** (all carry `rishiSessionId`):
  ```json
  { "type": "allowance_remaining", "rishiSessionId": "...", "remainingCredits": 42, "remainingIntervals": 12 }
  { "type": "session_ending", "rishiSessionId": "..." }
  { "type": "session_ended", "rishiSessionId": "...", "reason": "voice_session_time_cap" }
  { "type": "session_error", "rishiSessionId": "...", "code": "bad_client_message", "message": "human-readable description" }
  { "type": "snapshot", "rishiSessionId": "...", "status": "active", "remainingCredits": 42, "remainingIntervals": 12 }
  { "type": "snapshot", "rishiSessionId": "...", "status": "terminal", "reason": "provider_hangup_failed" }
  ```
  `reason` values: `"voice_session_time_cap"`, `"trial_credits_exhausted"`, `"registration_timeout"`, `"plan_voice_allowance_exhausted"`, `"provider_hangup_failed"` (transient-notification-only — never a durable terminal cause on the server, but the client must still treat it as "stop the mic now"). `snapshot.status` is one of `"pending_registration"`, `"active"`, `"terminal"`; `reason`/`remainingCredits`/`remainingIntervals` are present or absent exactly as shown above (never assume all three). The DO sends exactly ONE `snapshot` immediately on every successful upgrade (fresh connect or reconnect) — authoritative current state, not a delta.
- **Client → server:** `{ "type": "client_ack" }` — optional, advisory only, never affects server enforcement.

This plan does not modify the Worker, `packages/shared`, or any other app package's public API. It adds two new files to `RishiVoice` only.

---

## File structure

- **Create** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlMessage.swift` — the `ControlMessage` decodable enum plus its two nested value enums, `ControlTerminalReason` and `ControlSnapshotStatus`. Decode-only (the client never needs to re-encode a message the server sent it).
- **Create** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift` — the `ControlTerminalSignal` struct and the `ControlWebSocketClient` actor: connect, the receive loop, decode-and-dispatch, the reconnect/backoff loop, `disconnect()`, `reconnect()`, `sendClientAck()`.
- **Modify** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift` — append the two new files to the package's public-surface index (this file is comments-only; see its own header).

No changes to `Package.swift` — `RishiCore` (for `TokenProvider`) and `RishiLogging` (for `Log`) are already dependencies of `RishiVoice`.

---

## Design decisions (read before implementing)

**1. Isolation: `actor`, not a MainActor class, not a bare struct + lock.**
`RishiVoice` (like all `apps/apple/Packages/*` targets) has no `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting — only the `rishi` app target does (`apps/apple/docs/SWIFT-CONCURRENCY-RULES.md`, "Default isolation contract"). Inside a package, types are `nonisolated` by default. `ControlWebSocketClient` has shared mutable state that two concurrency domains touch — the receive loop (an unstructured `Task`) and the public API surface a caller invokes from wherever it lives (likely another actor or the MainActor voice-session presenter) — which is exactly "Pattern D" from that ADR: "When two or more concurrency domains write to the same state, model it as a Swift `actor`." The ADR names `EntitlementService` and `ReconnectController` as the existing precedent for this exact pattern; this plan follows it rather than inventing a lock-based `final class @unchecked Sendable` (the ADR's only sanctioned alternative is reserved for database-backed stores and system-framework callback shims, neither of which applies here).

**2. Observation surface: `AsyncStream` (general) + a mandatory callback (terminal-only) — not `@Observable`.**
`@Observable` is reserved in this codebase for MainActor-owned UI-presentation state (see `VoiceSessionState`, `@MainActor @Observable`, driven by the `RealtimeVoiceSession` actor calling `state.apply(...)`). `ControlWebSocketClient` is not UI state — it is a transport/session-support service, the same category as `EntitlementService`, which exposes its continuous value stream as `nonisolated let currentLevel: AsyncStream<EntitlementLevel>` built from a stored `Continuation`. `ControlWebSocketClient.messages` copies that exact shape for `ControlMessage`. Separately, the terminal signal gets a dedicated, mandatory `onTerminal` callback supplied at `init` — the same shape as `ReconnectController.Callbacks` (also this package), which already establishes "init-supplied `@Sendable async` callbacks driving the owner" as an idiom here. A terminal state is unlike every other value on the stream: the spec says "a terminal state ALWAYS stops the local microphone and voice UI," and a stream case can be missed by an incomplete `switch` or an early-`break`; a required (no default, non-optional) callback parameter cannot be forgotten by a caller without a compiler error.

**3. Reconnect: automatic, internal, unbounded attempts, capped backoff — plus a manual `reconnect()` escape hatch.**
The spec's instruction is "The app must reconnect its WebSocket while a session is active." This plan does not track "is the session active" (that ownership stays with the voice-session-flow-wiring plan), so `ControlWebSocketClient` reconnects automatically on any *unexpected* disconnect and keeps trying indefinitely — never reaching a terminal "give up" state on its own — because losing this control channel temporarily is a UX-only regression, not a fatal one: the actual voice audio keeps flowing over the separate OpenAI WebRTC connection regardless of this WebSocket's state. This deliberately differs from `ReconnectController`'s bounded `maxReconnects: Int = 3` ladder, whose exhaustion is fatal (`.failed(.networkLost)`) because THAT reconnect loop is protecting the audio transport itself. Backoff here doubles 1s→2s→4s→8s→16s and then holds at a 30s ceiling (same shape as `RealtimeVoiceSession`'s default `backoff` closure, extended with a ceiling instead of a hard cap on attempts). The caller can also call `reconnect()` directly (e.g. on app foreground, or in response to a network-reachability change) to force an immediate retry ahead of the current backoff delay. The two paths that STOP reconnecting entirely are: (a) the client itself already saw a terminal message (`session_ended` or a terminal `snapshot`) — nothing to reconnect to, the session is over; or (b) the caller called `disconnect()` — an explicit, intentional close.

**4. `session_error` vs `session_ended`/terminal `snapshot`: different exposure shape, on purpose.**
`session_error` only ever reaches a caller through the general `messages` stream, as `ControlMessage.sessionError`. It never triggers `onTerminal`, because it is advisory (the spec: "setup or reconciliation failures," not a hangup). `session_ended` and a terminal `snapshot` are the only two shapes that trigger `onTerminal`, gated by `ControlMessage.isTerminal`, a single source of truth used both to decide when to call `onTerminal` and when to stop reconnecting.

**5. Decoding: a custom `init(from:)`, and defensive `.unknown(String)` cases for `reason`/`status`.**
`ControlMessage` is a discriminated union keyed by a `type` string field — Swift's synthesized `Codable` cannot express this, so `Task 1` writes `init(from decoder:)` by hand, switching on `type`. `ControlTerminalReason` and `ControlSnapshotStatus` each add an `.unknown(String)` case with custom decoding, so that if the server ships a new reason or status value before this client is updated, decoding degrades gracefully (the message still decodes, callers can log the raw string) instead of throwing and dropping the entire message — which would be especially bad for a terminal message, since a dropped terminal message is exactly the "microphone kept running past session end" failure the spec is trying to prevent.

---

## Task 1: `ControlMessage` decodable enum

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlMessage.swift`

- [ ] **Step 1: Write the file**

```swift
// apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlMessage.swift

import Foundation

/// Reason a voice session reached a terminal state, as reported by the
/// Worker's control WebSocket (`session_ended.reason` or a terminal
/// `snapshot.reason`). Mirrors `VoiceSessionTerminalReason | HangupFailureReason`
/// from `workers/worker/src/durable-objects/voice-session/messages.ts` — see
/// `docs/superpowers/plans/2026-07-17-voice-control-websocket.md`,
/// "Exports for downstream plans", for the authoritative server-side list.
///
/// `.providerHangupFailed` is a transient WebSocket notification only — the
/// spec (`docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`,
/// "Control WebSocket") is explicit that the server never writes it to the
/// durable terminal-reason column. A client must still treat it exactly like
/// every other case here: stop the microphone now. There is no separate,
/// weaker handling for it in this type on purpose.
///
/// `.unknown` future-proofs against the server adding a new reason string
/// before this app ships an update. Decoding an unrecognized reason must
/// never throw and drop the surrounding message — see this file's decoding
/// extension.
public enum ControlTerminalReason: Sendable, Equatable {
    case voiceSessionTimeCap
    case trialCreditsExhausted
    case registrationTimeout
    case planVoiceAllowanceExhausted
    case providerHangupFailed
    case unknown(String)
}

extension ControlTerminalReason: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "voice_session_time_cap": self = .voiceSessionTimeCap
        case "trial_credits_exhausted": self = .trialCreditsExhausted
        case "registration_timeout": self = .registrationTimeout
        case "plan_voice_allowance_exhausted": self = .planVoiceAllowanceExhausted
        case "provider_hangup_failed": self = .providerHangupFailed
        default: self = .unknown(raw)
        }
    }
}

/// Current session status carried on every `snapshot` message. Mirrors
/// `VoiceSessionStatus` from `workers/worker/src/durable-objects/voice-session/sql.ts`.
public enum ControlSnapshotStatus: Sendable, Equatable {
    case pendingRegistration
    case active
    case terminal
    case unknown(String)
}

extension ControlSnapshotStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "pending_registration": self = .pendingRegistration
        case "active": self = .active
        case "terminal": self = .terminal
        default: self = .unknown(raw)
        }
    }
}

/// One decoded frame from the Worker's per-voice-session control WebSocket
/// (`GET /api/voice-sessions/{id}/control`). See
/// `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`,
/// "Control WebSocket", for the product contract and
/// `docs/superpowers/plans/2026-07-17-voice-control-websocket.md`,
/// "Exports for downstream plans", for the verbatim JSON shapes this
/// decoder implements.
///
/// Decode-only by design: every case here is a server → client message.
/// The one client → server shape (`{"type":"client_ack"}`) is a fixed
/// literal sent by `ControlWebSocketClient`, not modeled as a case of this
/// type — it never needs to be decoded, and giving it a case here would
/// invite a caller to mistakenly expect it on the `messages` stream.
public enum ControlMessage: Sendable, Equatable {
    case allowanceRemaining(rishiSessionId: String, remainingCredits: Int, remainingIntervals: Int)
    case sessionEnding(rishiSessionId: String)
    case sessionEnded(rishiSessionId: String, reason: ControlTerminalReason)
    case sessionError(rishiSessionId: String, code: String, message: String)
    case snapshot(
        rishiSessionId: String,
        status: ControlSnapshotStatus,
        remainingCredits: Int?,
        remainingIntervals: Int?,
        reason: ControlTerminalReason?
    )

    /// `true` for the two shapes that mean "stop the microphone and voice UI
    /// now": a `session_ended` message, or a `snapshot` whose
    /// `status == .terminal`. `ControlWebSocketClient` uses exactly this
    /// check to decide when to invoke its dedicated `onTerminal` callback —
    /// see that type's doc comment for why a second, unmissable signal
    /// exists alongside the general `messages` stream.
    public var isTerminal: Bool {
        switch self {
        case .sessionEnded:
            return true
        case .snapshot(_, let status, _, _, _):
            return status == .terminal
        case .allowanceRemaining, .sessionEnding, .sessionError:
            return false
        }
    }

    /// Present on every variant — convenience accessor for callers that
    /// log or route by session without a full `switch`.
    public var rishiSessionId: String {
        switch self {
        case .allowanceRemaining(let id, _, _): return id
        case .sessionEnding(let id): return id
        case .sessionEnded(let id, _): return id
        case .sessionError(let id, _, _): return id
        case .snapshot(let id, _, _, _, _): return id
        }
    }
}

extension ControlMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case rishiSessionId
        case remainingCredits
        case remainingIntervals
        case reason
        case code
        case message
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let rishiSessionId = try container.decode(String.self, forKey: .rishiSessionId)

        switch type {
        case "allowance_remaining":
            self = .allowanceRemaining(
                rishiSessionId: rishiSessionId,
                remainingCredits: try container.decode(Int.self, forKey: .remainingCredits),
                remainingIntervals: try container.decode(Int.self, forKey: .remainingIntervals)
            )
        case "session_ending":
            self = .sessionEnding(rishiSessionId: rishiSessionId)
        case "session_ended":
            self = .sessionEnded(
                rishiSessionId: rishiSessionId,
                reason: try container.decode(ControlTerminalReason.self, forKey: .reason)
            )
        case "session_error":
            self = .sessionError(
                rishiSessionId: rishiSessionId,
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "snapshot":
            self = .snapshot(
                rishiSessionId: rishiSessionId,
                status: try container.decode(ControlSnapshotStatus.self, forKey: .status),
                remainingCredits: try container.decodeIfPresent(Int.self, forKey: .remainingCredits),
                remainingIntervals: try container.decodeIfPresent(Int.self, forKey: .remainingIntervals),
                reason: try container.decodeIfPresent(ControlTerminalReason.self, forKey: .reason)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unrecognized control message type: \(type)"
            )
        }
    }
}
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
swift test --package-path apps/apple/Packages/RishiVoice
```

Expected: builds and runs the existing `RishiVoiceTests` suite with no new failures (this file adds a standalone type; nothing else references it yet, so no other file changes are needed for this step to pass).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlMessage.swift
git commit -m "feat(ios): add ControlMessage decodable enum for the voice control WebSocket"
```

---

## Task 2: `ControlWebSocketClient` actor

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift`

- [ ] **Step 1: Write the file**

```swift
// apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift

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
public actor ControlWebSocketClient {

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
        case .snapshot(_, _, _, _, let r):
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
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptConnect()
        }
    }
}
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
swift test --package-path apps/apple/Packages/RishiVoice
```

Expected: builds and runs clean. If `swift build` reports `URL.append(path:)` unavailable, confirm the package's deployment target in `apps/apple/Packages/RishiVoice/Package.swift` is still `.iOS(.v17)` / `.macOS(.v14)` (it is, as of this plan; `append(path:)` requires iOS 16+ / macOS 13+). If `URLSessionWebSocketTask.Message` reports the `@unknown default` case as unreachable/unnecessary under the SDK in use, that is a warning, not an error — leave it; it is intentional forward-compatibility with a Foundation type this package does not control.

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift
git commit -m "feat(ios): add ControlWebSocketClient actor with reconnect and terminal signal"
```

---

## Task 3: Update the package's public-API index

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift`

- [ ] **Step 1: Add the new types to the "Services" section**

Open `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift`. Change:

```swift
// MARK: - Services
//
// RealtimeVoiceSession        — `Service/RealtimeVoiceSession.swift`. Actor. The session
//                                lifecycle: start -> connect -> stream -> stop.
// RealtimeAPIAdapter          — `Service/RealtimeAPIAdapter.swift`. RealtimeClientAPI built
//                                on OpenAI's Realtime SDK. The app injects this in prod.
// EphemeralKeyFetcher         — `Service/EphemeralKeyFetcher.swift`. Actor. Mints short-lived
//                                Realtime keys via the Worker.
// VoiceTranscriptBridge       — `Service/VoiceTranscriptBridge.swift`. Actor. Forwards voice
//                                transcripts into the chat conversation as Message rows.
```

to:

```swift
// MARK: - Services
//
// RealtimeVoiceSession        — `Service/RealtimeVoiceSession.swift`. Actor. The session
//                                lifecycle: start -> connect -> stream -> stop.
// RealtimeAPIAdapter          — `Service/RealtimeAPIAdapter.swift`. RealtimeClientAPI built
//                                on OpenAI's Realtime SDK. The app injects this in prod.
// EphemeralKeyFetcher         — `Service/EphemeralKeyFetcher.swift`. Actor. Mints short-lived
//                                Realtime keys via the Worker.
// VoiceTranscriptBridge       — `Service/VoiceTranscriptBridge.swift`. Actor. Forwards voice
//                                transcripts into the chat conversation as Message rows.
// ControlWebSocketClient      — `Service/ControlWebSocketClient.swift`. Actor. Owns one Worker
//                                control WebSocket per voice session: allowance/warning/error
//                                messages via `messages: AsyncStream<ControlMessage>`,
//                                terminal state via a mandatory `onTerminal` callback,
//                                automatic capped-backoff reconnect.
```

And add a new "Models / Types" entry. Change:

```swift
// MARK: - Models / Types
//
// RealtimeConnectionStatus    — `Service/RealtimeClientAPI.swift`. Connection lifecycle enum.
// TranscriptRole              — `Service/RealtimeClientAPI.swift`. .user / .assistant.
// RealtimeTranscriptEvent     — `Service/RealtimeClientAPI.swift`. A single transcript delta.
// RealtimeClientError         — `Service/RealtimeClientAPI.swift`. Error wrapper for the client.
// EphemeralKey                — `Service/EphemeralKeyFetcher.swift`. Short-lived realtime key.
```

to:

```swift
// MARK: - Models / Types
//
// RealtimeConnectionStatus    — `Service/RealtimeClientAPI.swift`. Connection lifecycle enum.
// TranscriptRole              — `Service/RealtimeClientAPI.swift`. .user / .assistant.
// RealtimeTranscriptEvent     — `Service/RealtimeClientAPI.swift`. A single transcript delta.
// RealtimeClientError         — `Service/RealtimeClientAPI.swift`. Error wrapper for the client.
// EphemeralKey                — `Service/EphemeralKeyFetcher.swift`. Short-lived realtime key.
// ControlMessage              — `Service/ControlMessage.swift`. Decoded control-WebSocket frame:
//                                .allowanceRemaining / .sessionEnding / .sessionEnded /
//                                .sessionError / .snapshot.
// ControlTerminalReason       — `Service/ControlMessage.swift`. Why a session ended, as reported
//                                by the server (voiceSessionTimeCap, trialCreditsExhausted, ...).
// ControlSnapshotStatus       — `Service/ControlMessage.swift`. .pendingRegistration / .active /
//                                .terminal, carried on every `snapshot` message.
// ControlTerminalSignal       — `Service/ControlWebSocketClient.swift`. Payload delivered to
//                                `ControlWebSocketClient`'s `onTerminal` callback.
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
swift test --package-path apps/apple/Packages/RishiVoice
```

Expected: builds clean (this file is comments-only — nothing to typecheck differently, but this confirms the edit didn't break the file's syntax as a Swift source file, e.g. an unbalanced `/*`/`*/` or stray backtick issue).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift
git commit -m "docs(ios): index ControlWebSocketClient in RishiVoice's public API surface"
```

---

## Self-review

**Spec coverage** (against `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`, "Control WebSocket", and the "Exact contract facts" in this plan's originating task):

- "The app connects only to the public Worker route" → Task 2's `controlURL()` builds `{baseURL}/api/voice-sessions/{id}/control` with scheme flipped to `wss`/`ws`; no direct DO address is ever constructed client-side.
- Standard bearer-token auth on the upgrade request → Task 2's `attemptConnect()` sets `Authorization: Bearer <token>` from `RishiCore.TokenProvider`, matching `WorkerClient.buildRequest`'s exact header-setting pattern.
- All six server → client JSON shapes decode correctly, including the two optional-field branches of `snapshot` → Task 1's `ControlMessage.init(from:)`, one case per shape, `decodeIfPresent` for the fields that are absent depending on `status`.
- "The app must reconnect its WebSocket while a session is active and recover state from the ledger after reconnecting" → Task 2's `scheduleReconnect()`/`attemptConnect()` loop; "recover state" requires no extra client logic because the server always sends a fresh `snapshot` on every successful upgrade (this plan's "Design decisions" #3 and the Prerequisite section both call this out explicitly — there is deliberately no history-replay code in this plan).
- "A terminal state always stops the local microphone and voice UI" → Task 2's `markTerminal()` + the mandatory (non-optional, no default) `onTerminal` init parameter; "Design decisions" #2 explains why this is a dedicated callback and not just another `messages` case.
- `session_error` handled distinctly from `session_ended` → `ControlMessage.isTerminal` returns `false` for `.sessionError`; only `.sessionEnded` and a terminal `.snapshot` reach `markTerminal()`. Covered in "Design decisions" #4.
- "The control WebSocket may carry an explicit client close acknowledgement, but the server never derives duration or authorization from it" → `sendClientAck()` and `disconnect()`'s best-effort `client_ack` send, both documented as fire-and-forget/non-authoritative.
- Client → server `client_ack` shape → the fixed `clientAckJSON` literal, matching the worker's `ClientControlMessageSchema` exactly (`{"type":"client_ack"}`, no other fields).

Out of scope by design (explicitly deferred to the voice-session-flow-wiring plan, per this plan's task description): constructing `ControlWebSocketClient` from `ServiceGraphFactory`/`VoiceSessionPresenter`, session-active tracking, actually stopping the microphone/audio session on `onTerminal`, and any UI (allowance HUD, warning banner, terminal alert).

**Placeholder scan:** no "TBD"/"TODO"/"fill in details" in any task. Both new files are complete, compilable Swift — every code block is the literal file contents, not an excerpt.

**Type consistency:** `ControlMessage`, `ControlTerminalReason`, `ControlSnapshotStatus` (Task 1) are referenced by `ControlWebSocketClient`/`ControlTerminalSignal` (Task 2) with the exact same case names and associated-value labels throughout (`.sessionEnded(rishiSessionId:reason:)`, `.snapshot(rishiSessionId:status:remainingCredits:remainingIntervals:reason:)`). `isTerminal`, `rishiSessionId`, `messages`, `onTerminal`, `latestMessage`, `connect()`, `reconnect()`, `disconnect()`, `sendClientAck()` are named identically between this plan's prose (Design decisions, Exports section below) and the actual code blocks.

---

## Go/no-go signal

**Ship this.** The client is additive — a new actor and a new decodable enum in one existing package, with zero call sites anywhere else in the app yet (that wiring is the next plan's job), so there is no way this plan regresses currently-shipping behavior. `swift test --package-path apps/apple/Packages/RishiVoice` passing is sufficient confidence for a transport-only addition with no persisted state and no UI. The one thing worth a manual sanity check once the voice-session-flow-wiring plan wires this in: confirm on a real device that an airplane-mode toggle mid-session triggers the reconnect path and that `onTerminal` fires within one round trip of the server's next `session_ended`/terminal `snapshot` after reconnecting — but that is an integration concern for the next plan, not a reason to hold this one.

---

## Exports for downstream plans

**Types (both in `RishiVoice`, both `public`):**
- `ControlMessage` (`Service/ControlMessage.swift`) — `Sendable, Equatable, Decodable` enum. Cases: `.allowanceRemaining(rishiSessionId: String, remainingCredits: Int, remainingIntervals: Int)`, `.sessionEnding(rishiSessionId: String)`, `.sessionEnded(rishiSessionId: String, reason: ControlTerminalReason)`, `.sessionError(rishiSessionId: String, code: String, message: String)`, `.snapshot(rishiSessionId: String, status: ControlSnapshotStatus, remainingCredits: Int?, remainingIntervals: Int?, reason: ControlTerminalReason?)`. Computed: `.isTerminal: Bool`, `.rishiSessionId: String`.
- `ControlTerminalReason` (`Service/ControlMessage.swift`) — `Sendable, Equatable, Decodable` enum: `.voiceSessionTimeCap`, `.trialCreditsExhausted`, `.registrationTimeout`, `.planVoiceAllowanceExhausted`, `.providerHangupFailed`, `.unknown(String)`.
- `ControlSnapshotStatus` (`Service/ControlMessage.swift`) — `Sendable, Equatable, Decodable` enum: `.pendingRegistration`, `.active`, `.terminal`, `.unknown(String)`.
- `ControlTerminalSignal` (`Service/ControlWebSocketClient.swift`) — `Sendable, Equatable` struct: `rishiSessionId: String`, `reason: ControlTerminalReason`.

**`ControlWebSocketClient` (`Service/ControlWebSocketClient.swift`) — `public actor`:**

```swift
public init(
    baseURL: URL,
    tokenProvider: any TokenProvider,
    rishiSessionId: String,
    urlSession: URLSession = .shared,
    backoff: @escaping @Sendable (Int) -> Duration = ControlWebSocketClient.defaultBackoff,
    onTerminal: @escaping @Sendable (ControlTerminalSignal) async -> Void
)

public nonisolated let messages: AsyncStream<ControlMessage>
public private(set) var latestMessage: ControlMessage?   // actor-isolated; read via `await`

public func connect() async      // call once, after the voice session exists server-side
public func reconnect() async    // force an immediate retry (e.g. app foreground); no-op if terminal
public func disconnect() async   // intentional close; stops the internal reconnect loop; idempotent
public func sendClientAck() async
```

**How the voice-session-flow-wiring plan should call this:**
1. Construct one `ControlWebSocketClient` per voice session (right after the `POST /api/voice-sessions` response, matching the spec's Voice Chat flow step 3), passing an `onTerminal` closure that stops the local microphone/voice UI and surfaces `signal.reason` to the presenter. This is the ONLY reliable termination signal — do not rely on filtering `messages` for `.sessionEnded`/terminal `.snapshot` instead.
2. Call `await client.connect()` once. Reconnection while the session is active is automatic; no caller-side polling or retry logic is needed.
3. Subscribe to `client.messages` (`for await message in await client.messages { ... }` from a `Task`) to drive an allowance/warning HUD from `.allowanceRemaining` and `.sessionEnding`, and to log/report `.sessionError` as non-fatal.
4. Call `await client.reconnect()` on app-foreground (or a network-reachability callback) if faster resync than the current backoff delay is desired.
5. Call `await client.disconnect()` when the owning session ends for a reason this client did not itself detect (user manually leaves, app-level session teardown) — safe to call even after `onTerminal` already fired.

**Terminal reason values this plan already decodes** (no downstream mapping table needed — `ControlTerminalReason` is exhaustive over the current server contract plus a forward-compatible `.unknown(String)`): `voiceSessionTimeCap`, `trialCreditsExhausted`, `registrationTimeout`, `planVoiceAllowanceExhausted`, `providerHangupFailed`.
