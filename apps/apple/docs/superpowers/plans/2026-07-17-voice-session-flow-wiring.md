# Voice session flow wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **TDD override:** this plan intentionally contains **no test-writing steps**, per explicit user override. Every step is verified by `swift test --package-path apps/apple/Packages/RishiCore`, `swift test --package-path apps/apple/Packages/RishiVoice`, or `xcrun --sdk iphonesimulator swiftc -typecheck <file>` for app-target files under `apps/apple/rishi/` — never by a new test assertion. A few pre-existing test/fake files are touched ONLY where a public-API change (new protocol requirement, new enum case, new required-looking init param) would otherwise fail to compile; those edits are called out explicitly as "keep the build green," not new test coverage. Automated test alignment for the new flow is a deferred follow-up, matching the rest of this 16-plan set (see `2026-07-17-voice-sessions-route.md`'s identical override).

**Goal:** Rewrite the iOS voice-session-start sequence in `RealtimeVoiceSession` (package `RishiVoice`) so it drives the new multi-step protocol from the no-card-credit-trial spec's "Voice flow" — `POST /api/voice-sessions` → OpenAI WebRTC connect → capture + register the provider call ID → open the control WebSocket → react to `allowance_remaining` / `session_ending` / `session_ended` — while degrading, byte-for-byte, to today's single-step ephemeral-key flow whenever the new dependency (`sessionCoordinator`) isn't supplied. Every failure point (session-create rejection, WebRTC connect failure, missing/late call-ID registration) maps onto the app's existing `VoiceSessionStatus`/`VoiceFailureAlert` error-presentation surface, extended with new cases rather than replaced.

**Architecture:** `RealtimeVoiceSession.start()` branches into two private methods sharing the existing mic-permission + audio-mode-claim prefix: `startLegacyFlow` (today's `EphemeralKeyFetcher` → `client.connect()` → `.live`, moved verbatim, zero behavior change) and `startTrialVoiceSession` (new: `VoiceSessionCoordinating.startSession()` → `client.connect()` → `client.providerCallId` → `VoiceSessionCoordinating.registerCall()` → `.live` → open `ControlSocketConnecting`, whose concrete production type, `ControlWebSocketClient`, reconnects on its own — no external reconnect trigger needed). The branch is selected by whether `sessionCoordinator` is nil, which lets `VoiceSessionPresenter` gate the entire new flow behind one `private static let isTrialVoiceSessionFlowEnabled` constant, defaulted `false` for a staged rollout — the plan's own "Go/no-go signal" covers the recommended rollout order now that both of this plan's sibling dependencies have landed. Two protocol seams (`VoiceSessionCoordinating`, `ControlSocketConnecting`) keep `RealtimeVoiceSession` testable without a live worker or WebSocket, mirroring the existing `EphemeralKeyFetching`/`RealtimeClientAPI` pattern; `ControlSocketConnecting` wraps the already-landed `ControlWebSocketClient`/`ControlMessage`/`ControlTerminalReason`/`ControlTerminalSignal` types directly rather than redefining parallel ones. `RealtimeClientAPI` is widened with one new `providerCallId: String? { get async }` requirement so `RealtimeVoiceSession` (which only holds `any RealtimeClientAPI`) can read the already-landed, real `RealtimeAPIAdapter.providerCallId` property — that widening decision was explicitly deferred to this plan by the "realtime-call-id-capture" plan's own "Exports for downstream plans" section.

**Tech Stack:** Swift 6 strict concurrency (actors, `Sendable`), `URLSession`-backed `WorkerClient` (existing, in `RishiCore`), Swift Testing (existing suite; not extended by this plan), SwiftUI (`RishiVoice`'s `VoiceStatusBadge`/`VoiceSessionView`/`VoiceFailureAlert`).

---

## Dependency note — read this before starting

This plan wires together three things from this same 16-plan series. **All three had landed by the time this plan was finalized** — re-checked immediately before writing Tasks 8–12 below, superseding an earlier draft of those tasks that had to assume unlanded APIs:

1. **`workers/worker/src/routes/voice-sessions.ts`'s `POST /` and `POST /:id/register-call`** — landed per `docs/superpowers/plans/2026-07-17-voice-sessions-route.md`'s "Exports for downstream plans" section. This plan's Task 3 encodes that exact wire contract.
2. **`RealtimeAPIAdapter.providerCallId`**, landed per the "realtime-call-id-capture" plan (`apps/apple/docs/superpowers/plans/2026-07-17-realtime-call-id-capture.md`). It is a real (non-stub), lock-guarded, synchronous `public var providerCallId: String? { get }` on the concrete `RealtimeAPIAdapter` class — **not** part of the `RealtimeClientAPI` protocol. That plan's own "Exports for downstream plans" section explicitly defers the decision of *how* to expose it to code that only holds `any RealtimeClientAPI` (i.e. `RealtimeVoiceSession`) to this plan. Task 10 makes that decision: it widens `RealtimeClientAPI` with `var providerCallId: String? { get async }`, which `RealtimeAPIAdapter`'s existing synchronous property satisfies with zero changes (a sync witness can satisfy an `async` protocol requirement in Swift).
3. **`ControlWebSocketClient`**, landed per the "voice-control-websocket-client" plan (`apps/apple/docs/superpowers/plans/2026-07-17-voice-control-websocket-client.md`). Its real, exact shape — `messages: AsyncStream<ControlMessage>`, `connect()`/`reconnect()`/`disconnect()`/`sendClientAck()` all `async` with no `throws`, and a **mandatory `onTerminal` callback supplied at `init`** (not a separate connection-state stream) — differs from an earlier draft of this plan's Task 8, which (written before this sibling landed) assumed a hand-rolled message enum and a `connectionStateStream()` requirement. Task 8 below reflects the REAL, landed shape: it wraps `ControlMessage`/`ControlTerminalReason`/`ControlTerminalSignal` directly (no redefinition) and drops the connection-state stream entirely, since `ControlWebSocketClient` reconnects automatically and internally — there is nothing for `RealtimeVoiceSession` to trigger.

None of the three integration points behind this plan's own dependencies are stubbed in the tasks below — every seam this plan adds (`VoiceSessionCoordinating`, `ControlSocketConnecting`, the widened `RealtimeClientAPI.providerCallId`) has a real production implementation to wire against today. The `VoiceSessionPresenter.isTrialVoiceSessionFlowEnabled` flag (Task 12) still defaults to `false` — not because a dependency is missing, but as a standard staged-rollout gate for a flow this size; see "Go/no-go signal" at the end for the recommended flip sequence.

---

## Prerequisite — read the actual current files before editing

Re-verify these with `Read`/`rg -n` before touching them; other unrelated changes may have shifted line numbers since this plan was written.

- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift` — the actor this plan rewrites. Currently: `start()` runs a single flow (`requestingMic → fetchingKey → connecting → live`), `end()` tears down the reconnect controller, responder task, client, and audio mode.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/EphemeralKeyFetcher.swift` — untouched by this plan. Stays the reconnect path's key source (see "Production gotchas" for why the reconnect path deliberately does NOT re-run session-create/register-call).
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeClientAPI.swift` — the protocol this plan widens with one new `providerCallId` requirement.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift` — **read-only for this plan.** Already has a real `providerCallId` property (landed by "realtime-call-id-capture"); this plan verifies conformance via `rg`, does not edit this file.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift` and `.../Service/ControlMessage.swift` — landed by "voice-control-websocket-client". This plan adds one conformance clause to the former, does not touch the latter.
- `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Fakes/FakeRealtimeClient.swift` — the test double; needs a new `providerCallId` property to keep compiling (`swift test` builds this target regardless of which specific tests run).
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionStatus.swift` — defines `KeyFetchFailure`, `VoiceSessionFailureReason`, `VoiceSessionStatus`. This plan adds cases to all three via pure *additions* (no renames), so no other switch site over the pre-existing cases needs touching except the two genuinely-exhaustive UI switches below.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceStatusBadge.swift` and `.../UI/VoiceSessionView.swift` — both have exhaustive (no `default:`) switches over `VoiceSessionStatus`; both need the two new cases added or the package fails to compile.
- `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceFailureAlert.swift` — exhaustive switches over `VoiceSessionFailureReason`; same requirement.
- `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift` — a pre-existing *smoke* test (not a behavior test) whose explicit stated purpose (see its doc comment) is "regressions where a new `VoiceSessionStatus` case is added but the UI doesn't fan out the switch." Its two status arrays are updated in Task 5 purely to preserve that existing guarantee — this is enum-case housekeeping, not new test-writing.
- `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift` — app-level glue that constructs `RealtimeVoiceSession` today with 5 required + 3 optional params (`clientFactory`/`keyFetcherFactory` already exist as factories). This plan adds two more factories using the identical pattern.
- `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerClient.swift` — the actor whose 4xx decode path (currently lines ~216–237; re-check) this plan fixes to also accept the new routes' flat error-envelope shape.
- `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/ErrorEnvelope.swift` — the nested `{ error: { code, message } }` decode target most existing routes use.
- `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerErrorCode.swift` — the existing named-constant convention (`WorkerErrorCode.billingInactive`) this plan extends.
- `apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/RealtimeAPI.swift` — the sibling `RealtimeClientSecretsEndpoint`/`BookContextSnapshot`/`BookOutlineDTO` this plan's new endpoints reuse (`BookContextSnapshot`/`BookOutlineDTO`) or pattern-match (`RealtimeClientSecretsEndpoint`'s sparse-encode `Body`).

## A critical, easy-to-miss wire-contract bug this plan must fix first

`workers/worker/src/routes/voice-session-errors.ts` (landed per `2026-07-17-voice-sessions-route.md`) returns errors as **`{ "error": "<message string>", "code": "<WIRE_CODE>" }`** — a **flat** object. `WorkerClient.performAttempt`'s existing 4xx branch decodes only the **nested** `ErrorEnvelope` shape (`{ "error": { "code": ..., "message": ... } }`) that most other worker routes use. Decoding the flat shape as `ErrorEnvelope` fails silently (the existing code swallows the failure with `try?`), so today, calling either new voice-session endpoint through `WorkerClient.send` would **always** produce the generic fallback `RishiError.network(code: "http_4xx", message: "HTTP 402")` — never `INSUFFICIENT_TRIAL_CREDITS`, `VOICE_SESSION_ALREADY_ACTIVE`, etc. Every error-code branch this plan's classifiers (`VoiceSessionStartFailure`, `VoiceSessionRegistrationFailure`) rely on would silently fall through to `.serviceUnavailable`/`.unknown`. Task 1 fixes this at the root (`WorkerClient`) rather than working around it per-endpoint, and is backward-compatible with every existing route (nested shape is still tried first).

---

## File structure

| File | Change |
| --- | --- |
| `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/ErrorEnvelope.swift` | **Modify.** Add `FlatErrorEnvelope`. |
| `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerClient.swift` | **Modify.** 4xx decode tries nested, then flat, then falls back. |
| `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerErrorCode.swift` | **Modify.** Add the 10 voice-session wire codes. |
| `apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/VoiceSessionsAPI.swift` | **Create.** `CreateVoiceSessionEndpoint`, `RegisterVoiceCallEndpoint`. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionStatus.swift` | **Modify.** Add `VoiceSessionStartFailure`, `VoiceSessionRegistrationFailure`; extend `VoiceSessionFailureReason` and `VoiceSessionStatus`. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceStatusBadge.swift` | **Modify.** Handle 2 new `VoiceSessionStatus` cases. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift` | **Modify.** Handle 2 new cases in `orbColor`. |
| `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift` | **Modify.** Add 2 new cases to the existing coverage arrays (build-green housekeeping, not new tests). |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceFailureAlert.swift` | **Modify.** Title/body/action for the 3 new failure-reason cases; new `PrimaryAction.dismiss`. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift` | **Modify.** Add allowance/warning fields + mutators. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlSocketConnecting.swift` | **Create.** Protocol wrapping the landed `ControlWebSocketClient`'s real surface (`messages`/`connect`/`reconnect`/`disconnect`/`sendClientAck`) — no new message/state types. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift` | **Modify (1 line).** Add `: ControlSocketConnecting` conformance to the actor's declaration. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceSessionAPIClient.swift` | **Create.** `VoiceSessionCoordinating`, `StartedVoiceSession`, `VoiceSessionAPIClient`. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeClientAPI.swift` | **Modify.** Widen with `providerCallId: String? { get async }`. |
| `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Fakes/FakeRealtimeClient.swift` | **Modify.** Add `providerCallId` + `setProviderCallId(_:)` test driver (build-green, not new tests). |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift` | **Modify (major).** New init params, `start()` branch, control-socket wiring via the mandatory `onTerminal` callback, `end()` teardown. |
| `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift` | **Modify.** Doc-index entries for the new public symbols. |
| `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift` | **Modify.** Two new factories + the `isTrialVoiceSessionFlowEnabled` flag. |

---

### Task 1: Fix `WorkerClient`'s 4xx decode to accept the new routes' flat error shape

**Files:**
- Modify: `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/ErrorEnvelope.swift`
- Modify: `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerClient.swift`

- [ ] **Step 1: Add the flat envelope type**

Append to `ErrorEnvelope.swift` (same file, same access level as the existing `struct ErrorEnvelope`):

```swift
/// Decoded shape of the flat `{ "error": "<message>", "code": "<CODE>" }`
/// 4xx/5xx error body used by the voice-session routes
/// (`workers/worker/src/routes/voice-session-errors.ts` and
/// `workers/worker/src/routes/voice-sessions.ts`'s own 400/502 responses) —
/// distinct from the nested `ErrorEnvelope` shape most other worker routes
/// use. `WorkerClient` tries `ErrorEnvelope` first, then this, before
/// falling back to a generic code. See
/// `2026-07-17-voice-session-flow-wiring.md` Task 1.
struct FlatErrorEnvelope: Codable, Sendable, Hashable {
    let error: String
    let code: String
}
```

- [ ] **Step 2: Replace the 4xx decode branch in `WorkerClient.performAttempt`**

Change:

```swift
        case 400..<500:
            let envelope = (try? decoder.decode(ErrorEnvelope.self, from: data))
                ?? ErrorEnvelope(error: .init(code: "http_4xx", message: "HTTP \(status)"))
            throw RishiError.network(code: envelope.code, message: envelope.message)
```

to:

```swift
        case 400..<500:
            let (code, message) = decodeWorkerErrorFields(from: data, status: status)
            throw RishiError.network(code: code, message: message)
```

- [ ] **Step 3: Add the decode-fallback helper**

Add this as a new private method on the `WorkerClient` actor (near `performAttempt`, e.g. immediately after it):

```swift
    /// Decodes a 4xx/5xx body into `(code, message)`. Tries the nested
    /// `{ error: { code, message } }` shape most worker routes use
    /// (`ErrorEnvelope`) first — preserving every existing route's behavior
    /// unchanged — then the flat `{ error, code }` shape the voice-session
    /// routes return, then falls back to a generic `http_4xx` code so an
    /// unparseable body never throws a decoding error instead of the
    /// intended `RishiError.network`. See
    /// `2026-07-17-voice-session-flow-wiring.md` Task 1.
    private func decodeWorkerErrorFields(from data: Data, status: Int) -> (code: String, message: String) {
        if let nested = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return (nested.code, nested.message)
        }
        if let flat = try? decoder.decode(FlatErrorEnvelope.self, from: data) {
            return (flat.code, flat.error)
        }
        return ("http_4xx", "HTTP \(status)")
    }
```

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiCore
```

Expected: builds clean; `WorkerClientTests.status403DecodesEnvelope` (nested shape) and `status4xxDoesNotRetry` (empty body) still pass unchanged — both paths are covered by the new helper's first/last branches respectively.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/ErrorEnvelope.swift apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerClient.swift
git commit -m "fix(apple): decode the flat worker error envelope shape voice-session routes use"
```

---

### Task 2: Add the voice-session `WorkerErrorCode` constants

**Files:**
- Modify: `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerErrorCode.swift`

- [ ] **Step 1: Add the constants**

Append inside the existing `enum WorkerErrorCode { ... }` (after `billingInactive`):

```swift
    // MARK: - POST /api/voice-sessions (2026-07-17-voice-sessions-route.md)

    /// 409 — this account already has a live voice session.
    public static let voiceSessionAlreadyActive = "VOICE_SESSION_ALREADY_ACTIVE"
    /// 402 — fewer than 2 trial credits remain (or the paid-plan equivalent).
    public static let insufficientTrialCredits = "INSUFFICIENT_TRIAL_CREDITS"
    /// 502 — the ledger session was created but OpenAI's client-secret mint failed. Retryable.
    public static let openAIMintFailed = "OPENAI_MINT_FAILED"

    // MARK: - POST /api/voice-sessions/:id/register-call

    /// 400 — `callId`/`nonce` missing or empty in the request body.
    public static let invalidRegisterCallBody = "INVALID_REGISTER_CALL_BODY"
    /// 400 — `:id` doesn't match this account's currently active session.
    public static let voiceSessionIdMismatch = "VOICE_SESSION_ID_MISMATCH"
    /// 400 — the registration nonce didn't verify.
    public static let registrationNonceInvalid = "REGISTRATION_NONCE_INVALID"
    /// 404 — no active session exists (already terminal, or grace-period expired).
    public static let noActiveVoiceSession = "NO_ACTIVE_VOICE_SESSION"
    /// 409 — this session already completed registration once.
    public static let callAlreadyRegistered = "CALL_ALREADY_REGISTERED"
    /// 409 — this exact nonce was already consumed.
    public static let registrationNonceReplayed = "REGISTRATION_NONCE_REPLAYED"
    /// 500 — unexpected server error (shared by both voice-session routes).
    public static let internalError = "INTERNAL_ERROR"
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiCore
```

Expected: builds clean (no consumer yet — that's Task 4).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiCore/Sources/RishiCore/RishiAPI/WorkerErrorCode.swift
git commit -m "feat(apple): add voice-session worker error-code constants"
```

---

### Task 3: Add the two voice-session `WorkerEndpoint`s

**Files:**
- Create: `apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/VoiceSessionsAPI.swift`

- [ ] **Step 1: Write the endpoints**

```swift
// apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/VoiceSessionsAPI.swift
import Foundation

// MARK: - POST /api/voice-sessions

/// Starts a Rishi voice session per the no-card-credit-trial spec's "Voice
/// flow" step 1–2: the ledger verifies the applicable trial/plan allowance,
/// creates a Rishi session ID + single-use registration nonce, records the
/// session cap, and mints an OpenAI Realtime client secret — all in one
/// synchronous round trip (`2026-07-17-voice-sessions-route.md`).
///
/// Body fields are the same optional book-context shape
/// `RealtimeClientSecretsEndpoint` (`RealtimeAPI.swift`) already sends —
/// duplicated here (rather than shared) because the two endpoints are
/// independent wire contracts on the worker side (separate Hono routes,
/// separate Zod schemas) even though the payload shape happens to match
/// today.
public struct CreateVoiceSessionEndpoint: WorkerEndpointWithBody {
    public typealias Response = CreatedVoiceSession

    public let method: HTTPMethod = .POST
    public let path: String = "/api/voice-sessions"
    public let body: Body

    public init(language: String? = nil, bookContext: BookContextSnapshot? = nil) {
        self.body = Body(
            language: language,
            bookId: bookContext?.bookId,
            currentPage: bookContext?.currentPage,
            pageText: bookContext?.pageText,
            outline: bookContext?.outline,
            activeParagraphText: bookContext?.activeParagraphText
        )
    }

    /// Sparse on encode — nil fields are omitted, so a book-less
    /// `CreateVoiceSessionEndpoint()` emits `{}`, matching the worker's
    /// `CreateVoiceSessionBodySchema.partial()`.
    public struct Body: Encodable, Sendable, Equatable {
        public let language: String?
        public let bookId: UUID?
        public let currentPage: Int?
        public let pageText: String?
        public let outline: BookOutlineDTO?
        public let activeParagraphText: String?

        enum CodingKeys: String, CodingKey {
            case language
            case bookId = "book_id"
            case currentPage = "current_page"
            case pageText = "page_text"
            case outline
            case activeParagraphText = "active_paragraph_text"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let language { try container.encode(language, forKey: .language) }
            if let bookId { try container.encode(bookId, forKey: .bookId) }
            if let currentPage { try container.encode(currentPage, forKey: .currentPage) }
            if let pageText { try container.encode(pageText, forKey: .pageText) }
            if let outline { try container.encode(outline, forKey: .outline) }
            if let activeParagraphText {
                try container.encode(activeParagraphText, forKey: .activeParagraphText)
            }
        }
    }

    /// Wire shape is already flat camelCase
    /// (`{ rishiSessionId, nonce, clientSecret, capIntervals }`) per
    /// `2026-07-17-voice-sessions-route.md`'s "Exports for downstream
    /// plans" — no custom `CodingKeys` needed.
    public struct CreatedVoiceSession: Decodable, Sendable, Equatable {
        public let rishiSessionId: String
        public let nonce: String
        public let clientSecret: String
        public let capIntervals: Int
    }
}

// MARK: - POST /api/voice-sessions/:id/register-call

/// Registers the OpenAI `call_id` the vendored Swift Realtime connector
/// captured from the `Location` header of its WebRTC call-creation response,
/// per the no-card-credit-trial spec's "Voice flow" step 3–5. `:id` is the
/// `rishiSessionId` `CreateVoiceSessionEndpoint` returned.
///
/// Every non-2xx response from this endpoint means the caller MUST close the
/// just-opened OpenAI WebRTC connection and show a retryable error — see
/// `2026-07-17-voice-sessions-route.md`'s "Exports for downstream plans"
/// table (this plan's `VoiceSessionRegistrationFailure` classifies exactly
/// that table).
public struct RegisterVoiceCallEndpoint: WorkerEndpointWithBody {
    public typealias Response = RegisterCallResponse

    public let method: HTTPMethod = .POST
    public let path: String
    public let body: Body

    public init(rishiSessionId: String, callId: String, nonce: String) {
        self.path = "/api/voice-sessions/\(rishiSessionId)/register-call"
        self.body = Body(callId: callId, nonce: nonce)
    }

    public struct Body: Encodable, Sendable, Equatable {
        public let callId: String
        public let nonce: String
    }

    public struct RegisterCallResponse: Decodable, Sendable, Equatable {
        public let ok: Bool
    }
}
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiCore
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/VoiceSessionsAPI.swift
git commit -m "feat(apple): add CreateVoiceSessionEndpoint and RegisterVoiceCallEndpoint"
```

---

### Task 4: Add the two new failure classifiers + extend `VoiceSessionFailureReason`

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionStatus.swift`

- [ ] **Step 1: Add `VoiceSessionStartFailure` and `VoiceSessionRegistrationFailure`**

Add these two new enums immediately after the existing `KeyFetchFailure` enum (same file):

```swift
/// Why `POST /api/voice-sessions` (the no-card-credit-trial "Voice flow"
/// step 1–2) failed. Mirrors `KeyFetchFailure`'s classify-from-`RishiError`
/// pattern, keyed off the wire codes `2026-07-17-voice-sessions-route.md`
/// documents.
public enum VoiceSessionStartFailure: Sendable, Equatable {
    /// 409 — this account already has a live voice session.
    case alreadyActive
    /// 402 — fewer than 2 trial credits remain (or paid-plan equivalent exhausted).
    case insufficientCredits
    /// 502 — the ledger session was created but the OpenAI mint failed. Retryable.
    case mintFailed
    /// 401 — session expired / signed out.
    case unauthorized
    /// 500 or any other unmapped 4xx/5xx — server route failing.
    case serviceUnavailable
    /// Transport failure (no connectivity).
    case network
    /// Anything else, carries a description.
    case unknown(String)

    public static func classify(_ error: any Error) -> VoiceSessionStartFailure {
        guard let rishiError = error as? RishiError else { return .unknown(String(describing: error)) }
        switch rishiError {
        case .unauthenticated:
            return .unauthorized
        case .network(let code, _):
            switch code {
            case WorkerErrorCode.voiceSessionAlreadyActive: return .alreadyActive
            case WorkerErrorCode.insufficientTrialCredits:  return .insufficientCredits
            case WorkerErrorCode.openAIMintFailed:          return .mintFailed
            default:                                         return .serviceUnavailable
            }
        case .networkFailure:
            return .network
        default:
            return .unknown(String(describing: error))
        }
    }
}

/// Why `POST /api/voice-sessions/:id/register-call` failed (the no-card-
/// credit-trial "Voice flow" step 3–5), OR why registration was never even
/// attempted (`.missingCallId` — the vendored connector never captured a
/// call ID, e.g. a missing `Location` header). Every case here means the
/// caller MUST have already closed the just-opened OpenAI WebRTC connection
/// — see `RealtimeVoiceSession.startTrialVoiceSession`.
public enum VoiceSessionRegistrationFailure: Sendable, Equatable {
    /// The vendored connector never captured a provider call ID after a
    /// successful `connect()` — no HTTP call was even made.
    case missingCallId
    /// 400 — `callId`/`nonce` missing or empty (should not happen from this client; defensive).
    case invalidBody
    /// 400 — `:id` doesn't match this account's active session.
    case sessionIdMismatch
    /// 400 — the registration nonce didn't verify.
    case nonceInvalid
    /// 404 — no active session exists (already terminal, or grace period expired).
    case noActiveSession
    /// 409 — this session already completed registration once.
    case callAlreadyRegistered
    /// 409 — this exact nonce was already consumed.
    case nonceReplayed
    /// 401 — session expired / signed out.
    case unauthorized
    /// 500 or any other unmapped 4xx/5xx.
    case serviceUnavailable
    /// Transport failure (no connectivity).
    case network
    /// Anything else, carries a description.
    case unknown(String)

    public static func classify(_ error: any Error) -> VoiceSessionRegistrationFailure {
        guard let rishiError = error as? RishiError else { return .unknown(String(describing: error)) }
        switch rishiError {
        case .unauthenticated:
            return .unauthorized
        case .network(let code, _):
            switch code {
            case WorkerErrorCode.invalidRegisterCallBody:     return .invalidBody
            case WorkerErrorCode.voiceSessionIdMismatch:      return .sessionIdMismatch
            case WorkerErrorCode.registrationNonceInvalid:    return .nonceInvalid
            case WorkerErrorCode.noActiveVoiceSession:        return .noActiveSession
            case WorkerErrorCode.callAlreadyRegistered:       return .callAlreadyRegistered
            case WorkerErrorCode.registrationNonceReplayed:   return .nonceReplayed
            default:                                           return .serviceUnavailable
            }
        case .networkFailure:
            return .network
        default:
            return .unknown(String(describing: error))
        }
    }
}
```

- [ ] **Step 2: Extend `VoiceSessionFailureReason`**

Change:

```swift
public enum VoiceSessionFailureReason: Sendable, Equatable {
    case micDenied
    case keyFetch(KeyFetchFailure)
    case connect
    case networkLost
    case audioSession
    case unknown(String)
}
```

to:

```swift
public enum VoiceSessionFailureReason: Sendable, Equatable {
    case micDenied
    case keyFetch(KeyFetchFailure)
    /// `POST /api/voice-sessions` failed. Trial-voice-session flow only.
    case sessionStart(VoiceSessionStartFailure)
    /// `POST /api/voice-sessions/:id/register-call` failed, or the call ID
    /// was never captured. Trial-voice-session flow only.
    case callRegistration(VoiceSessionRegistrationFailure)
    case connect
    case networkLost
    case audioSession
    /// The control WebSocket's mandatory `onTerminal` callback fired
    /// (`session_ended` or a terminal `snapshot`). `reason` is
    /// `ControlTerminalReason` — the exact type exported by the landed
    /// "voice-control-websocket-client" plan (`Service/ControlMessage.swift`
    /// in this package): `.voiceSessionTimeCap`, `.trialCreditsExhausted`,
    /// `.registrationTimeout`, `.planVoiceAllowanceExhausted`,
    /// `.providerHangupFailed`, or `.unknown(String)` for forward
    /// compatibility with a server-added reason. Trial-voice-session flow
    /// only.
    case sessionTerminated(reason: ControlTerminalReason)
    case unknown(String)
}
```

- [ ] **Step 3: Extend `VoiceSessionStatus`**

Change:

```swift
public enum VoiceSessionStatus: Sendable, Equatable {
    case idle
    case requestingMic
    case fetchingKey
    case connecting
    case live
    case reconnecting(attempt: Int)
    case ending
    case ended
    case failed(reason: VoiceSessionFailureReason)
}
```

to:

```swift
public enum VoiceSessionStatus: Sendable, Equatable {
    case idle
    case requestingMic
    /// Legacy flow only: minting a plain ephemeral key (no Rishi session).
    case fetchingKey
    /// Trial-voice-session flow only: `POST /api/voice-sessions`.
    case creatingSession
    /// Both flows: OpenAI WebRTC `connect()`.
    case connecting
    /// Trial-voice-session flow only: `POST /api/voice-sessions/:id/register-call`.
    case registeringCall
    case live
    case reconnecting(attempt: Int)
    case ending
    case ended
    case failed(reason: VoiceSessionFailureReason)
}
```

Update the doc comment above the enum (the ASCII FSM diagram) to add a second diagram for the trial-voice-session flow — see the diagram already drafted in Task 11's file header; copy it here too so the two source-of-truth comments (status enum + session actor) agree.

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: **fails to build** at this point — `VoiceStatusBadge.swift` and `VoiceSessionView.swift`'s exhaustive switches don't yet handle `.creatingSession`/`.registeringCall`. That's expected; Task 5 fixes it. (If you're executing tasks strictly in order, this failing build is the correct, temporary state between Task 4 and Task 5 — do not skip ahead to "fix the whole package" here, just confirm the *only* new errors are the two missing-case diagnostics in those two files.)

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionStatus.swift
git commit -m "feat(apple): add VoiceSessionStartFailure/VoiceSessionRegistrationFailure + FSM states"
```

---

### Task 5: Fan out the two new `VoiceSessionStatus` cases through the UI switches

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceStatusBadge.swift`
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift`
- Modify: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift`

- [ ] **Step 1: `VoiceStatusBadge.label`**

Change:

```swift
        case .idle:                return "Idle"
        case .requestingMic:       return "Requesting mic"
        case .fetchingKey:         return "Connecting…"
        case .connecting:          return "Connecting…"
        case .live:                return "Live"
```

to:

```swift
        case .idle:                return "Idle"
        case .requestingMic:       return "Requesting mic"
        case .fetchingKey:         return "Connecting…"
        case .creatingSession:     return "Starting…"
        case .connecting:          return "Connecting…"
        case .registeringCall:     return "Confirming…"
        case .live:                return "Live"
```

- [ ] **Step 2: `VoiceStatusBadge.indicatorColor`**

Change:

```swift
        case .reconnecting, .connecting, .fetchingKey, .requestingMic:
            return RishiColor.textSecondary
```

to:

```swift
        case .reconnecting, .connecting, .fetchingKey, .creatingSession, .registeringCall, .requestingMic:
            return RishiColor.textSecondary
```

- [ ] **Step 3: `VoiceSessionView.orbColor`**

Change:

```swift
        case .connecting, .fetchingKey, .requestingMic, .reconnecting:
            return RishiColor.textSecondary
```

to:

```swift
        case .connecting, .fetchingKey, .creatingSession, .registeringCall, .requestingMic, .reconnecting:
            return RishiColor.textSecondary
```

- [ ] **Step 4: Keep the existing smoke test's coverage list in sync**

In `VoiceUISnapshotTests.swift`, both `statusBadgeForEveryStatus()` and `sessionViewConstructsForEveryStatus()` build a hardcoded `[VoiceSessionStatus]` array whose own doc comment states its purpose is catching exactly this situation ("a new `VoiceSessionStatus` case is added but the UI doesn't fan out the switch"). Add the two new cases to both arrays, right after `.fetchingKey`:

In `statusBadgeForEveryStatus()`, change:

```swift
            .fetchingKey,
            .connecting,
```

to:

```swift
            .fetchingKey,
            .creatingSession,
            .connecting,
            .registeringCall,
```

In `sessionViewConstructsForEveryStatus()`, apply the identical change.

- [ ] **Step 5: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean; `VoiceUISnapshotTests` passes (it only trips `.body`, no new assertions).

- [ ] **Step 6: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceStatusBadge.swift apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift
git commit -m "feat(apple): fan the new creatingSession/registeringCall states through voice UI"
```

---

### Task 6: Extend `VoiceFailureAlert` for the 3 new failure reasons

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceFailureAlert.swift`

- [ ] **Step 1: Add the `.dismiss` primary action**

Change:

```swift
    public enum PrimaryAction: Equatable, Sendable {
        /// Deep-link to the Settings app — `.micDenied` only, because there is
        /// no in-app way to re-request the microphone after a denial.
        case openSettings
        /// Restart the failed session (every non-`.micDenied` reason).
        case retry
    }
```

to:

```swift
    public enum PrimaryAction: Equatable, Sendable {
        /// Deep-link to the Settings app — `.micDenied` only, because there is
        /// no in-app way to re-request the microphone after a denial.
        case openSettings
        /// Restart the failed session (every non-`.micDenied`,
        /// non-exhaustion reason).
        case retry
        /// No further client action is available yet — the alert is
        /// acknowledge-only. Used for exhaustion/upgrade-shaped reasons
        /// (`.sessionStart(.insufficientCredits)` and terminal reasons like
        /// `trial_credits_exhausted`) until the "no-card-onboarding-
        /// allowance-ui" plan's exhaustion/upgrade screen exists — see this
        /// plan's "Exports for downstream plans". Once that screen exists,
        /// route these through a new `.upgrade` action instead of `.dismiss`.
        case dismiss
    }
```

- [ ] **Step 2: Wire `primaryAction` through a dedicated mapper**

Change:

```swift
    public init(reason: VoiceSessionFailureReason, message: String?) {
        self.title = Self.title(for: reason)
        self.message = message ?? Self.bodyCopy(for: reason)
        self.primaryAction = (reason == .micDenied) ? .openSettings : .retry
    }
```

to:

```swift
    public init(reason: VoiceSessionFailureReason, message: String?) {
        self.title = Self.title(for: reason)
        self.message = message ?? Self.bodyCopy(for: reason)
        self.primaryAction = Self.primaryAction(for: reason)
    }

    private static func primaryAction(for reason: VoiceSessionFailureReason) -> PrimaryAction {
        switch reason {
        case .micDenied:
            return .openSettings
        case .sessionStart(.insufficientCredits):
            return .dismiss
        case .sessionTerminated(let terminationReason) where Self.isExhaustionReason(terminationReason):
            return .dismiss
        default:
            return .retry
        }
    }

    private static func isExhaustionReason(_ reason: ControlTerminalReason) -> Bool {
        switch reason {
        case .trialCreditsExhausted, .planVoiceAllowanceExhausted:
            return true
        case .voiceSessionTimeCap, .registrationTimeout, .providerHangupFailed, .unknown:
            return false
        }
    }
```

- [ ] **Step 3: Extend `title(for:)`**

Change:

```swift
    private static func title(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:    return "Microphone access needed"
        case .keyFetch(let failure):
            switch failure {
            case .unauthorized:         return "Sign-in required"
            case .subscriptionRequired: return "Pro required"
            case .serviceUnavailable:   return "Voice unavailable"
            case .network:              return "No connection"
            case .unknown:              return "Couldn't start the session"
            }
        case .connect:      return "Couldn't connect"
        case .networkLost:  return "Connection lost"
        case .audioSession: return "Audio setup failed"
        case .unknown:      return "Something went wrong"
        }
    }
```

to:

```swift
    private static func title(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:    return "Microphone access needed"
        case .keyFetch(let failure):
            switch failure {
            case .unauthorized:         return "Sign-in required"
            case .subscriptionRequired: return "Pro required"
            case .serviceUnavailable:   return "Voice unavailable"
            case .network:              return "No connection"
            case .unknown:              return "Couldn't start the session"
            }
        case .sessionStart(let failure):
            switch failure {
            case .alreadyActive:        return "Voice chat already active"
            case .insufficientCredits:  return "Trial credits used up"
            case .mintFailed:           return "Voice unavailable"
            case .unauthorized:         return "Sign-in required"
            case .serviceUnavailable:   return "Voice unavailable"
            case .network:              return "No connection"
            case .unknown:              return "Couldn't start the session"
            }
        case .callRegistration:
            return "Couldn't confirm the connection"
        case .connect:      return "Couldn't connect"
        case .networkLost:  return "Connection lost"
        case .audioSession: return "Audio setup failed"
        case .sessionTerminated(let reason):
            return Self.sessionTerminatedTitle(for: reason)
        case .unknown:      return "Something went wrong"
        }
    }

    private static func sessionTerminatedTitle(for reason: ControlTerminalReason) -> String {
        switch reason {
        case .voiceSessionTimeCap:          return "Time limit reached"
        case .trialCreditsExhausted:        return "Trial credits used up"
        case .planVoiceAllowanceExhausted:  return "Voice Chat allowance used up"
        case .registrationTimeout:          return "Couldn't confirm the connection"
        case .providerHangupFailed:         return "Voice chat ended"
        case .unknown:                      return "Voice chat ended"
        }
    }
```

- [ ] **Step 4: Extend `bodyCopy(for:)`**

Change:

```swift
    private static func bodyCopy(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:
            return "Allow microphone access in Settings to talk with the AI."
        case .keyFetch(let failure):
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
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .connect:
            return "The voice service couldn't be reached. Try again in a moment."
        case .networkLost:
            return "We lost the connection after a few retries. Try again."
        case .audioSession:
            return "We couldn't configure audio. Make sure no other app is using the microphone."
        case .unknown(let msg):
            return msg.isEmpty ? "An unexpected error occurred." : msg
        }
    }
```

to:

```swift
    private static func bodyCopy(for reason: VoiceSessionFailureReason) -> String {
        switch reason {
        case .micDenied:
            return "Allow microphone access in Settings to talk with the AI."
        case .keyFetch(let failure):
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
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .sessionStart(let failure):
            switch failure {
            case .alreadyActive:
                return "You already have a voice session running. Close it before starting another."
            case .insufficientCredits:
                // Deliberately generic copy: the "no-card-onboarding-
                // allowance-ui" plan's exhaustion/upgrade screen had not
                // landed when this was written — see this plan's "Exports
                // for downstream plans".
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
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .callRegistration(let failure):
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
                return detail.isEmpty ? "An unexpected error occurred." : detail
            }
        case .connect:
            return "The voice service couldn't be reached. Try again in a moment."
        case .networkLost:
            return "We lost the connection after a few retries. Try again."
        case .audioSession:
            return "We couldn't configure audio. Make sure no other app is using the microphone."
        case .sessionTerminated(let reason):
            return Self.sessionTerminatedBody(for: reason)
        case .unknown(let msg):
            return msg.isEmpty ? "An unexpected error occurred." : msg
        }
    }

    private static func sessionTerminatedBody(for reason: ControlTerminalReason) -> String {
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
```

- [ ] **Step 5: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean; `VoiceFailureAlertTests` (which only exercises the pre-existing reasons, none of the 3 new ones) still passes unchanged.

- [ ] **Step 6: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceFailureAlert.swift
git commit -m "feat(apple): map sessionStart/callRegistration/sessionTerminated to VoiceFailureAlert copy"
```

---

### Task 7: Extend `VoiceSessionState` with allowance + warning fields

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift`

- [ ] **Step 1: Add the fields and mutators**

Change:

```swift
@MainActor
@Observable
public final class VoiceSessionState {
    public var status: VoiceSessionStatus = .idle
    public var partialUserTranscript: String = ""
    public var partialAssistantTranscript: String = ""
    public var lastError: String?

    public init() {}
```

to:

```swift
@MainActor
@Observable
public final class VoiceSessionState {
    public var status: VoiceSessionStatus = .idle
    public var partialUserTranscript: String = ""
    public var partialAssistantTranscript: String = ""
    public var lastError: String?

    /// Remaining allowance, updated from the control WebSocket's
    /// `allowance_remaining` message (and the non-terminal branch of
    /// `snapshot`), per `ControlMessage`'s exact field names/types from the
    /// landed "voice-control-websocket-client" plan
    /// (`Service/ControlMessage.swift` in this package):
    /// `remainingCredits: Int` and `remainingIntervals: Int`, always sent
    /// together. `nil` before the first message arrives.
    public var remainingCredits: Int?
    public var remainingIntervals: Int?
    /// Set once the control WebSocket sends `session_ending` (final
    /// 30-second interval warning). Cleared by `reset()`. The app layer
    /// (e.g. `VoiceSessionView`) reads this to show a warning banner.
    public var isFinalInterval: Bool = false

    public init() {}
```

- [ ] **Step 2: Add the mutators**

Add after `recordError`:

```swift
    /// Applies a control-WebSocket allowance update — either an
    /// `allowance_remaining` message (both fields always present) or the
    /// non-terminal branch of a `snapshot` message (both fields optional
    /// per `ControlMessage.snapshot`'s decoding; pass through as given).
    public func applyAllowance(
        remainingCredits: Int?,
        remainingIntervals: Int?
    ) {
        if let remainingCredits { self.remainingCredits = remainingCredits }
        if let remainingIntervals { self.remainingIntervals = remainingIntervals }
    }

    /// Applies a control-WebSocket `session_ending` warning.
    public func applySessionEndingWarning() {
        isFinalInterval = true
    }
```

- [ ] **Step 3: Reset the new fields in `reset()`**

Change:

```swift
    public func reset() {
        self.status = .idle
        self.partialUserTranscript = ""
        self.partialAssistantTranscript = ""
        self.lastError = nil
    }
```

to:

```swift
    public func reset() {
        self.status = .idle
        self.partialUserTranscript = ""
        self.partialAssistantTranscript = ""
        self.lastError = nil
        self.remainingCredits = nil
        self.remainingIntervals = nil
        self.isFinalInterval = false
    }
```

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean; existing `VoiceSessionStateTests` (which doesn't touch the new fields) still passes.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift
git commit -m "feat(apple): add allowance/session-ending fields to VoiceSessionState"
```

---

### Task 8: Add the `ControlSocketConnecting` protocol seam

**Prerequisite — re-verify against the landed sibling before writing this task:** the "voice-control-websocket-client" plan (`apps/apple/docs/superpowers/plans/2026-07-17-voice-control-websocket-client.md`) has landed and its "Exports for downstream plans" section is the authority for everything below. It already defines, in this same package (`RishiVoice`, `Service/ControlMessage.swift` + `Service/ControlWebSocketClient.swift`):

- `ControlMessage` (`Sendable, Equatable, Decodable` enum) — `.allowanceRemaining(rishiSessionId: String, remainingCredits: Int, remainingIntervals: Int)`, `.sessionEnding(rishiSessionId: String)`, `.sessionEnded(rishiSessionId: String, reason: ControlTerminalReason)`, `.sessionError(rishiSessionId: String, code: String, message: String)`, `.snapshot(rishiSessionId: String, status: ControlSnapshotStatus, remainingCredits: Int?, remainingIntervals: Int?, reason: ControlTerminalReason?)`.
- `ControlTerminalReason` — `.voiceSessionTimeCap`, `.trialCreditsExhausted`, `.registrationTimeout`, `.planVoiceAllowanceExhausted`, `.providerHangupFailed`, `.unknown(String)`.
- `ControlTerminalSignal` (struct) — `rishiSessionId: String`, `reason: ControlTerminalReason`. Delivered exactly once via a **mandatory `onTerminal` callback supplied at `ControlWebSocketClient.init`** — NOT via the message stream. Per that plan's own words: *"This is the ONLY reliable termination signal — do not rely on filtering `messages` for `.sessionEnded`/terminal `.snapshot` instead."*
- `ControlWebSocketClient` (`public actor`) — `init(baseURL: URL, tokenProvider: any TokenProvider, rishiSessionId: String, urlSession: URLSession = .shared, backoff: ... = .defaultBackoff, onTerminal: @escaping @Sendable (ControlTerminalSignal) async -> Void)`; `public nonisolated let messages: AsyncStream<ControlMessage>`; `func connect() async` (no `throws`, no return value — errors surface only as reconnect-loop log events); `func reconnect() async`; `func disconnect() async`; `func sendClientAck() async`. **Reconnection while the session is active is fully automatic and internal** (unbounded attempts, capped exponential backoff) — there is no separate connection-state stream and no caller-side reconnect trigger to wire.

This plan does **not** reuse any of this task's original draft (a hand-rolled `ControlSocketMessage`/`ControlSocketConnectionState` pair with a `connectionStateStream()` requirement) — that draft predates the sibling landing and does not match its shape. `ControlSocketConnecting` below wraps the REAL types directly rather than redefining parallel ones, and drops the connection-state stream entirely since reconnect no longer needs external triggering.

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlSocketConnecting.swift`
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift` (add one conformance clause)

- [ ] **Step 1: Write the protocol**

```swift
// apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlSocketConnecting.swift
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
}
```

- [ ] **Step 2: Conform `ControlWebSocketClient` to the new protocol**

In `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift`, change the actor's declaration line from:

```swift
public actor ControlWebSocketClient {
```

to:

```swift
public actor ControlWebSocketClient: ControlSocketConnecting {
```

No other change to that file — every method/property this protocol requires (`messages`, `connect()`, `reconnect()`, `disconnect()`, `sendClientAck()`) already exists there with matching signatures (a synchronous `nonisolated let messages` satisfies a non-`async` protocol property requirement directly; the four methods are already actor-isolated `async` functions with no other parameters, matching the protocol exactly).

- [ ] **Step 3: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean (no consumer of `ControlSocketConnecting` yet — that's Task 11; the one-line conformance addition to `ControlWebSocketClient` has zero behavior change).

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlSocketConnecting.swift apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift
git commit -m "feat(apple): add ControlSocketConnecting protocol seam, conform ControlWebSocketClient"
```

---

### Task 9: Add `VoiceSessionCoordinating` + `VoiceSessionAPIClient`

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceSessionAPIClient.swift`

- [ ] **Step 1: Write the protocol, value type, and production client**

```swift
// apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceSessionAPIClient.swift
import Foundation
import RishiCore
import RishiLogging

/// Result of a successful `POST /api/voice-sessions` call. `nonce` is
/// single-use — retain it only long enough to call `registerCall` once, per
/// the no-card-credit-trial spec's "Voice flow" step 3.
public struct StartedVoiceSession: Sendable, Equatable {
    public let rishiSessionId: String
    public let nonce: String
    public let clientSecret: String
    public let capIntervals: Int

    public init(rishiSessionId: String, nonce: String, clientSecret: String, capIntervals: Int) {
        self.rishiSessionId = rishiSessionId
        self.nonce = nonce
        self.clientSecret = clientSecret
        self.capIntervals = capIntervals
    }
}

/// Injection seam for the two-step voice-session-creation flow. Production
/// wires `VoiceSessionAPIClient`; `RishiVoice` tests inject a stub. Mirrors
/// the existing `EphemeralKeyFetching` seam pattern exactly.
public protocol VoiceSessionCoordinating: Sendable {
    /// `POST /api/voice-sessions` — the no-card-credit-trial spec's "Voice
    /// flow" step 1–2. Throws `RishiError` (typically `.network(code:message:)`
    /// with one of the codes `VoiceSessionStartFailure.classify` maps, or
    /// `.unauthenticated`, or `.networkFailure`).
    func startSession(language: String?, bookContext: BookContextSnapshot?) async throws -> StartedVoiceSession

    /// `POST /api/voice-sessions/:id/register-call` — "Voice flow" step 3–5.
    /// Throws `RishiError` the same way; every thrown error means the caller
    /// must close the just-opened OpenAI WebRTC connection (see
    /// `VoiceSessionRegistrationFailure`).
    func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws
}

/// Production `VoiceSessionCoordinating`, backed by the existing
/// `WorkerClient`. Actor (not a plain struct) to match `EphemeralKeyFetcher`'s
/// concurrency shape — no mutable state today, but keeps the seam
/// actor-isolated in case a future retry/cache layer needs it.
public actor VoiceSessionAPIClient: VoiceSessionCoordinating {

    private let workerClient: WorkerClient

    public init(workerClient: WorkerClient) {
        self.workerClient = workerClient
    }

    public func startSession(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> StartedVoiceSession {
        let endpoint = CreateVoiceSessionEndpoint(language: language, bookContext: bookContext)
        do {
            let response = try await workerClient.send(endpoint)
            Log.event("voice.session.create.succeeded", level: .info, data: [
                "rishiSessionId": response.rishiSessionId,
                "capIntervals": String(response.capIntervals),
            ])
            return StartedVoiceSession(
                rishiSessionId: response.rishiSessionId,
                nonce: response.nonce,
                clientSecret: response.clientSecret,
                capIntervals: response.capIntervals
            )
        } catch {
            Log.event("voice.session.create.failed", level: .error, data: [
                "error": String(describing: error),
            ])
            throw error
        }
    }

    public func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws {
        let endpoint = RegisterVoiceCallEndpoint(rishiSessionId: rishiSessionId, callId: callId, nonce: nonce)
        do {
            _ = try await workerClient.send(endpoint)
            Log.event("voice.session.register_call.succeeded", level: .info, data: [
                "rishiSessionId": rishiSessionId,
            ])
        } catch {
            Log.event("voice.session.register_call.failed", level: .error, data: [
                "rishiSessionId": rishiSessionId,
                "error": String(describing: error),
            ])
            throw error
        }
    }
}
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceSessionAPIClient.swift
git commit -m "feat(apple): add VoiceSessionCoordinating + VoiceSessionAPIClient"
```

---

### Task 10: Widen `RealtimeClientAPI` with `providerCallId`, conform the fake

**Prerequisite — re-verify against the landed sibling:** the "realtime-call-id-capture" plan (`apps/apple/docs/superpowers/plans/2026-07-17-realtime-call-id-capture.md`) has landed. It already added a REAL (non-stub) `public var providerCallId: String? { get }` to the concrete `RealtimeAPIAdapter` class — lock-guarded, `nil` before any successful `connect()` and cleared on every `teardownActiveConversation()`/`disconnect()`. Its own "Exports for downstream plans" section is explicit that this property is deliberately **not** part of the `RealtimeClientAPI` protocol, and that deciding whether/how to widen the protocol so `RealtimeVoiceSession` (which only holds `any RealtimeClientAPI`) can read it is **this plan's job**. This task does that widening.

Because the real implementation already exists on `RealtimeAPIAdapter`, this task needs **no changes to `RealtimeAPIAdapter.swift` at all** — a plain, synchronous, non-throwing computed property satisfies an `async` protocol requirement in Swift without modification (the caller still writes `await`, but no suspension actually occurs). This task only widens the protocol and updates the test fake.

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeClientAPI.swift`
- Modify: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Fakes/FakeRealtimeClient.swift`

- [ ] **Step 1: Widen the protocol**

Add to `RealtimeClientAPI` (in `RealtimeClientAPI.swift`), immediately after `func currentStatus() async -> RealtimeConnectionStatus`:

```swift
    /// The OpenAI Realtime provider call ID captured from the `Location`
    /// header of the WebRTC call-creation response that the most recent
    /// successful `connect()` completed, per the no-card-credit-trial
    /// spec's "Voice flow" step 3. `nil` before any successful `connect()`,
    /// after `disconnect()`, or if that connect's response was missing/
    /// unparseable the header (the documented failure case that spec step
    /// 7 says must fail closed). Widens the protocol so
    /// `RealtimeVoiceSession` — which only holds `any RealtimeClientAPI` —
    /// can read the real, already-landed `RealtimeAPIAdapter.providerCallId`
    /// (see the "realtime-call-id-capture" plan's "Exports for downstream
    /// plans", which explicitly defers this widening decision to this
    /// plan). Marked `async` so a future implementation could involve a
    /// suspension point; `RealtimeAPIAdapter`'s existing synchronous
    /// lock-guarded property satisfies this requirement as-is.
    var providerCallId: String? { get async }
```

Verify `RealtimeAPIAdapter` now satisfies the widened protocol with zero changes:

```bash
rg -n "var providerCallId" apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift
```

Expected: one match, `public var providerCallId: String? { ... }` (added by the "realtime-call-id-capture" plan). If this returns no match, that sibling plan's Task 4 has not actually landed in code yet despite its plan file existing — stop and land it first; do not re-add a stub here (this task's whole point is to avoid a second, divergent `providerCallId` implementation).

- [ ] **Step 2: Conform `FakeRealtimeClient`**

Add a stored property near the other `_status`/etc. fields:

```swift
    private var _providerCallId: String?
```

Add near the other "Test drivers" (e.g. after `clearAllConnectFailures()`):

```swift
    /// Drive the value `providerCallId` returns. Defaults to `nil` (the
    /// "missing Location header" / not-yet-connected case) so tests must
    /// opt in to simulating a successful capture.
    public func setProviderCallId(_ callId: String?) {
        lock.withLock { _providerCallId = callId }
    }
```

Add to the `// MARK: - RealtimeClientAPI` section (near `currentStatus()`):

```swift
    public var providerCallId: String? {
        lock.withLock { _providerCallId }
    }
```

In `disconnect()`, reset it alongside the other teardown state. Change the `lock.withLock` block that currently reads:

```swift
        ) = lock.withLock {
            _disconnectCalls += 1
            _status = .disconnected
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
```

to:

```swift
        ) = lock.withLock {
            _disconnectCalls += 1
            _status = .disconnected
            _providerCallId = nil
            let e = errorContinuation; errorContinuation = nil
            let t = transcriptContinuation; transcriptContinuation = nil
            let tc = toolCallContinuation; toolCallContinuation = nil
            return (e, t, tc)
        }
```

- [ ] **Step 3: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean; every existing test using `FakeRealtimeClient` still passes (the new property is purely additive and its default `nil` doesn't change any existing assertion, since no existing test reads `providerCallId`). `RealtimeAPIAdapter`'s existing tests (`RealtimeAPIAdapterSmokeTests`, etc., added by the "realtime-call-id-capture" plan) are also unaffected — this task doesn't touch that file.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeClientAPI.swift apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Fakes/FakeRealtimeClient.swift
git commit -m "feat(apple): widen RealtimeClientAPI with providerCallId, conform FakeRealtimeClient"
```

---

### Task 11: Rewrite `RealtimeVoiceSession`

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift`

- [ ] **Step 1: Replace the file's full contents**

The changes touch the file header comment, every stored property block, `init`, `start()`, `end()`, and add several new private methods. Replace the entire file with:

```swift
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
    /// see `openControlSocket`. The factory itself never needs to `throw`
    /// or return `nil` for a real `ControlWebSocketClient` — constructing
    /// one cannot fail; only `connect()` can, and that failure is handled
    /// inside `openControlSocket`, not here.
    private let controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> any ControlSocketConnecting)?
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
        controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> any ControlSocketConnecting)? = nil,
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
        let socket = controlSocketFactory(rishiSessionId) { [weak self] signal in
            await self?.terminateFromControlSocket(reason: signal.reason)
        }
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
        case .allowanceRemaining(_, let remainingCredits, let remainingIntervals):
            await MainActor.run {
                state.applyAllowance(remainingCredits: remainingCredits, remainingIntervals: remainingIntervals)
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
        case .snapshot(_, _, let remainingCredits, let remainingIntervals, _):
            // A non-terminal snapshot (pendingRegistration/active) just
            // refreshes the allowance HUD with the authoritative current
            // value; a terminal snapshot is handled exclusively via
            // `onTerminal`, never here.
            await MainActor.run {
                state.applyAllowance(remainingCredits: remainingCredits, remainingIntervals: remainingIntervals)
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
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean. Every existing test that constructs `RealtimeVoiceSession(...)` (`RealtimeVoiceSessionTests.swift`, `RealtimeVoiceSessionBookContextTests.swift`, `RealtimeVoiceSessionPreemptionTests.swift`) omits `sessionCoordinator`/`controlSocketFactory`, which default to `nil` — those tests keep exercising `startLegacyFlow`, byte-for-byte the pre-existing code path, so they should continue to pass unchanged. If any fail, the most likely cause is a stray reference to a removed symbol rather than new-flow logic (the legacy flow's code is untouched, just moved into its own method).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift
git commit -m "feat(apple): rewrite RealtimeVoiceSession with the trial-voice-session flow"
```

---

### Task 12: Wire `VoiceSessionPresenter` (behind a flag)

**Files:**
- Modify: `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`

**Why `ServiceGraphFactory.swift` changes too:** `ControlWebSocketClient.init` requires `baseURL: URL` and `tokenProvider: any TokenProvider` (per the landed "voice-control-websocket-client" plan's real signature — it builds its own `wss://` upgrade request rather than routing through `WorkerClient`, which has no WebSocket method). `VoiceSessionPresenter` today only receives `workerClient: WorkerClient` (which keeps `baseURL`/`tokenProvider` `private`), so this task threads both values through as two new presenter dependencies, sourced from the same `baseURL`/`tokenProvider` locals `ServiceGraphFactory.build` already constructs (and already passes to `WorkerClient(baseURL:tokenProvider:)` at the top of that function).

- [ ] **Step 1: Add the feature flag + two factories to `VoiceSessionPresenter`**

Change:

```swift
    private let clientFactory: @MainActor () -> any RealtimeClientAPI
    private let keyFetcherFactory: @MainActor () -> any EphemeralKeyFetching

    private var bridgeTask: Task<Void, Never>?

    init(
        coordinator: AudioSessionCoordinator,
        workerClient: WorkerClient,
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate(),
        bookSearch: (any BookSearch)? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        clientFactory: (@MainActor () -> any RealtimeClientAPI)? = nil,
        keyFetcherFactory: (@MainActor () -> any EphemeralKeyFetching)? = nil
    ) {
        self.state = VoiceSessionState()
        self.coordinator = coordinator
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.userIdProvider = userIdProvider
        self.dirtyHook = dirtyHook
        self.micGate = micGate
        self.bookSearch = bookSearch
        self.embedderPrewarm = embedderPrewarm

        self.clientFactory = clientFactory ?? { RealtimeAPIAdapter() }
        self.keyFetcherFactory =
            keyFetcherFactory ?? {
                EphemeralKeyFetcher(workerClient: workerClient)
            }
    }
```

to:

```swift
    private let clientFactory: @MainActor () -> any RealtimeClientAPI
    private let keyFetcherFactory: @MainActor () -> any EphemeralKeyFetching
    private let sessionCoordinatorFactory: @MainActor () -> (any VoiceSessionCoordinating)?
    private let controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)

    private var bridgeTask: Task<Void, Never>?

    /// Feature flag for the no-card-credit-trial voice-session flow (session
    /// create → WebRTC connect → call-ID registration → control WebSocket).
    /// Both of this plan's sibling dependencies (`RealtimeAPIAdapter.providerCallId`
    /// and `ControlWebSocketClient`) are real, landed implementations as of
    /// this writing — this flag is a staged-rollout gate, not a
    /// missing-dependency guard. See `2026-07-17-voice-session-flow-wiring.md`'s
    /// "Go/no-go signal" for the recommended flip sequence (verify this
    /// plan's own `swift test`/typecheck steps pass first, then flip to
    /// `true` for an internal build before a general rollout).
    private static let isTrialVoiceSessionFlowEnabled = false

    init(
        coordinator: AudioSessionCoordinator,
        workerClient: WorkerClient,
        // Defaulted (not required) so every existing call site —
        // `ServiceGraphFactory` (updated explicitly in Step 3 below) and
        // the `VoiceSessionPresenter*Tests.swift` files that construct this
        // type directly with their own `StubTokenProvider` — keeps
        // compiling unchanged. The default is harmless: it's only ever
        // read by `controlSocketFactory`'s closure, which itself is a
        // no-op (`Self.isTrialVoiceSessionFlowEnabled == false`) unless a
        // caller also overrides `controlSocketFactory`.
        baseURL: URL = URL(string: "https://api.fidexa.org")!,
        tokenProvider: any TokenProvider = StaticTokenProvider(nil),
        messageStore: any MessageStore,
        conversationLookup: ConversationLookup,
        userIdProvider: @escaping @MainActor () -> UserID?,
        dirtyHook: any VoiceTranscriptDirtyHook,
        micGate: any MicPermissionGate = SystemMicPermissionGate(),
        bookSearch: (any BookSearch)? = nil,
        embedderPrewarm: (@Sendable () async -> Void)? = nil,
        clientFactory: (@MainActor () -> any RealtimeClientAPI)? = nil,
        keyFetcherFactory: (@MainActor () -> any EphemeralKeyFetching)? = nil,
        sessionCoordinatorFactory: (@MainActor () -> (any VoiceSessionCoordinating)?)? = nil,
        controlSocketFactory: (@Sendable (String, @escaping @Sendable (ControlTerminalSignal) async -> Void) -> (any ControlSocketConnecting)?)? = nil
    ) {
        self.state = VoiceSessionState()
        self.coordinator = coordinator
        self.workerClient = workerClient
        self.messageStore = messageStore
        self.conversationLookup = conversationLookup
        self.userIdProvider = userIdProvider
        self.dirtyHook = dirtyHook
        self.micGate = micGate
        self.bookSearch = bookSearch
        self.embedderPrewarm = embedderPrewarm

        self.clientFactory = clientFactory ?? { RealtimeAPIAdapter() }
        self.keyFetcherFactory =
            keyFetcherFactory ?? {
                EphemeralKeyFetcher(workerClient: workerClient)
            }
        self.sessionCoordinatorFactory = sessionCoordinatorFactory ?? {
            Self.isTrialVoiceSessionFlowEnabled ? VoiceSessionAPIClient(workerClient: workerClient) : nil
        }
        self.controlSocketFactory = controlSocketFactory ?? { rishiSessionId, onTerminal in
            guard Self.isTrialVoiceSessionFlowEnabled else { return nil }
            return ControlWebSocketClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                rishiSessionId: rishiSessionId,
                onTerminal: onTerminal
            )
        }
    }
```

- [ ] **Step 2: Pass the new dependencies into `RealtimeVoiceSession`**

Change:

```swift
        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: adapter,
            state: state,
            responderFactory: responderFactory,
            embedderPrewarm: embedderPrewarm
        )
```

to:

```swift
        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: adapter,
            state: state,
            sessionCoordinator: sessionCoordinatorFactory(),
            controlSocketFactory: controlSocketFactory,
            responderFactory: responderFactory,
            embedderPrewarm: embedderPrewarm
        )
```

- [ ] **Step 3: Thread `baseURL`/`tokenProvider` through `ServiceGraphFactory.build`**

`ServiceGraphFactory.build` already constructs both values (used to build `workerClient` itself). In `apps/apple/rishi/rishi/ServiceGraphFactory.swift`, find where `voicePresenter` is constructed:

```swift
        let voicePresenter = await MainActor.run {

            return VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                
                dirtyHook: voiceDirtyAdapter,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm
            )
        }
```

Change to:

```swift
        let voicePresenter = await MainActor.run {

            return VoiceSessionPresenter(
                coordinator: audioStack.coordinator,
                workerClient: workerClient,
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                messageStore: messageStore,
                conversationLookup: conversationLookup,
                userIdProvider: { [userIdBox] in userIdBox.value },
                
                dirtyHook: voiceDirtyAdapter,
                bookSearch: bookSearch,
                embedderPrewarm: embedderPrewarm
            )
        }
```

`baseURL` (a `URL`) and `tokenProvider` (the `RishiAuthTokenProvider` struct, already `any TokenProvider`-conforming) are both plain `let` locals already in scope earlier in the same function — no new construction needed, just pass-through.

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Voice/VoiceSessionPresenter.swift -I Packages/RishiVoice/.build/debug/Modules -I Packages/RishiCore/.build/debug/Modules 2>&1 | head -50
```

If the module-search-path flags above don't resolve locally (they depend on prior `swift build` output), the reliable fallback per `apps/apple/CLAUDE.md` is to run the full package test for `RishiVoice` (already green from Task 11) and defer the app-target typecheck to the MAIN orchestrator's end-of-phase `xcodebuild` pass — do not attempt `xcodebuild rishi` from this task per the CLAUDE.md 600s-stall warning.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift
git commit -m "feat(apple): wire VoiceSessionPresenter's trial-voice-session flag + factories"
```

---

### Task 13: Update the `RishiVoice+API.swift` doc index

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift`

- [ ] **Step 1: Add entries for the new public symbols**

Under `// MARK: - Services`, add after the `EphemeralKeyFetcher` line:

```swift
// VoiceSessionAPIClient       — `Service/VoiceSessionAPIClient.swift`. Actor. Creates a Rishi
//                                voice session + registers the OpenAI call ID via the Worker.
```

Under `// MARK: - Protocols`, add after `EphemeralKeyFetching`:

```swift
// VoiceSessionCoordinating    — `Service/VoiceSessionAPIClient.swift`. Protocol seam for tests.
// ControlSocketConnecting     — `Service/ControlSocketConnecting.swift`. Transport seam wrapping
//                                the landed ControlWebSocketClient (which conforms to it) —
//                                messages/connect/reconnect/disconnect/sendClientAck. Tests use
//                                a fake; the app uses the real ControlWebSocketClient.
```

Under `// MARK: - Models / Types`, add:

```swift
// StartedVoiceSession         — `Service/VoiceSessionAPIClient.swift`. Result of a successful
//                                POST /api/voice-sessions call.
// VoiceSessionStartFailure    — `State/VoiceSessionStatus.swift`. Why POST /api/voice-sessions failed.
// VoiceSessionRegistrationFailure — `State/VoiceSessionStatus.swift`. Why register-call failed
//                                (or the call ID was never captured).
```

(`ControlMessage`/`ControlTerminalReason`/`ControlSnapshotStatus`/`ControlTerminalSignal` are already indexed by the landed "voice-control-websocket-client" plan's own edit to this same file — do not re-add them here.)

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: builds clean (comment-only change).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift
git commit -m "docs(apple): index the new voice-session-flow-wiring public symbols"
```

---

### Task 14: Full-package verification

**Files:** none (verification only)

- [ ] **Step 1: `RishiCore`**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiCore
```

Expected: clean pass, including `WorkerClientTests` and `ErrorEnvelopeTests`.

- [ ] **Step 2: `RishiVoice`**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
swift test --package-path Packages/RishiVoice
```

Expected: clean pass — every pre-existing suite (`RealtimeVoiceSessionTests`, `RealtimeVoiceSessionBookContextTests`, `RealtimeVoiceSessionPreemptionTests`, `ReconnectControllerTests`, `VoiceSessionStateTests`, `VoiceFailureAlertTests`, `VoiceUISnapshotTests`) plus this plan's edits to them.

- [ ] **Step 3: App-target smoke typecheck**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Voice/VoiceSessionPresenter.swift 2>&1 | head -80
```

Per `apps/apple/CLAUDE.md`, this per-file typecheck is a fallback signal only (it will show unrelated "module not found" noise for `RishiVoice`/`RishiCore` unless the workspace has already been built once) — the canonical confirmation that the full app still builds is the MAIN orchestrator's end-of-phase `xcodebuild` run, not this task. Flag any error that specifically names a symbol this plan introduced (`VoiceSessionAPIClient`, `ControlSocketConnecting`, `sessionCoordinatorFactory`, `controlSocketFactory`, `isTrialVoiceSessionFlowEnabled`) as a real regression; ignore generic "no such module" noise.

- [ ] **Step 4: Commit (only if a fixup was needed)**

If Tasks 1–13 already committed cleanly, there is nothing new to commit here.

---

## Self-review

**Spec coverage** (against the no-card-credit-trial design's "Voice flow" and the pricing/trial-launch design's "Voice Chat flow" / "Latency and background-work contract"):

| Spec requirement | Covered by |
| --- | --- |
| Step 1 — "The app calls `POST /api/voice-sessions`." | Task 9 (`VoiceSessionAPIClient.startSession`), consumed by Task 11 (`startTrialVoiceSession`) |
| Step 2 — ledger verifies allowance, returns client secret | Task 3's `CreateVoiceSessionEndpoint` decodes exactly `2026-07-17-voice-sessions-route.md`'s response shape |
| Step 3 — "The vendored connector captures the OpenAI `call_id` ... and immediately registers it" | Task 10 (widens `RealtimeClientAPI` with the already-real `providerCallId`) + Task 11 (`startTrialVoiceSession` reads it immediately post-connect and calls `registerCall`) |
| Step 4 — ledger accepts the call ID once, accepts the control WebSocket | Task 9 (`registerCall`) + Task 11 (`openControlSocket` right after `.live`) |
| Step 5 — `allowance_remaining` / `session_ending` over the control WebSocket | Task 7 (`VoiceSessionState.applyAllowance`/`applySessionEndingWarning`) + Task 11 (`handleControlMessage`) |
| Step 6 — `session_ended` at account/period/session cap; client closes gracefully on the control message | Task 11 (`terminateFromControlSocket`, invoked from the `onTerminal` callback: stops mic via `client.disconnect()`, tears down, fails with the terminal reason) |
| Step 7 — "If the app fails to register the OpenAI call ID promptly, it must close the just-opened voice connection and show a retryable error." | Task 11's `startTrialVoiceSession`: both the missing-call-ID branch and every `registerCall` failure branch call `client.disconnect()` before `fail(...)` |
| "The app must reconnect its WebSocket while a session is active" (Control WebSocket section) | Satisfied entirely inside the landed `ControlWebSocketClient` (unbounded-attempt, capped-backoff internal reconnect) — this plan's `openControlSocket` (Task 11) needs no reconnect-trigger code of its own |
| "session creation and client-secret minting are synchronous and intentionally short" / "The app may begin its direct WebRTC negotiation before the registration acknowledgement returns" (Latency and background-work contract) | Task 11: `startTrialVoiceSession` calls `client.connect()` immediately after `startSession()` returns, and only THEN calls `registerCall` — matching "begins WebRTC before the registration ack," with the fail-closed teardown as the bounded grace-period enforcement on the client side |
| Error-code-to-UI mapping reusing the existing error-presentation pattern | Task 4 (`VoiceSessionStartFailure`/`VoiceSessionRegistrationFailure`, same `classify(_:)` shape as pre-existing `KeyFetchFailure`) + Task 6 (`VoiceFailureAlert` title/body/action) |
| `INSUFFICIENT_TRIAL_CREDITS` → exhaustion/upgrade screen, or generic + flagged follow-up if that plan hasn't landed | Task 6/11: generic copy + `.dismiss` action, explicitly flagged in "Exports for downstream plans" below (confirmed: "no-card-onboarding-allowance-ui" plan/component does not exist yet) |
| FSM extension: `creating_session → connecting_webrtc → registering_call → active → terminating/error` | Task 4 (`.creatingSession`, `.registeringCall` added; `.connecting`/`.live` reused; "terminating" maps onto existing `.ending → .ended` for user-initiated end, or `.failed(.sessionTerminated)` for server-driven end — documented in Task 11's file-header FSM diagram) |

**Placeholder scan:** no "TBD"/"TODO"/"fill in details" anywhere above. `RealtimeAPIAdapter.providerCallId` and `ControlWebSocketClient` are both real, already-landed implementations this plan wires against directly — the only thing gated behind a stub-like default is `VoiceSessionPresenter.isTrialVoiceSessionFlowEnabled` (Task 12), a deliberate staged-rollout flag, not a missing-dependency placeholder.

**Type consistency:** `StartedVoiceSession`'s fields (`rishiSessionId`, `nonce`, `clientSecret`, `capIntervals`) are produced once in Task 9 and consumed identically in Task 11 — no renamed fields. `VoiceSessionCoordinating.startSession`/`registerCall`'s signatures match between Task 9's protocol declaration, its `VoiceSessionAPIClient` implementation, and Task 11's call sites. `ControlSocketConnecting`'s four methods (Task 8) wrap the landed `ControlMessage`/`ControlTerminalReason`/`ControlTerminalSignal` types directly and are consumed identically in Task 11 with no field-name drift. `VoiceSessionStartFailure`/`VoiceSessionRegistrationFailure` cases used in Task 11's `Self.sessionStartMessage`/`Self.registrationMessage` exactly match the cases defined in Task 4, and the `WorkerErrorCode` constants referenced in Task 4's `classify(_:)` exactly match the names added in Task 2.

---

## Production gotchas

- **WebRTC-level reconnect does not re-register a new call ID.** `ReconnectController.handleTransientDisconnect()` (pre-existing, untouched) re-fetches a plain ephemeral key via `keyFetcher.fetch(language:)` and calls `client.connect()` again on a transient WebRTC drop — it does not go through `sessionCoordinator` at all. Per the landed "realtime-call-id-capture" plan's own "Exports for downstream plans" note, each such reconnect opens a genuinely new OpenAI Realtime call with a new `providerCallId` (that plan's `teardownActiveConversation()` clears the property before every `connect()`, including reconnects), so if the ledger's server-side usage ticking is keyed to the *first* registered call ID, a reconnected leg's usage may go unverified. That sibling plan explicitly left this decision to whichever plan next touches reconnect semantics — this plan does not attempt it (out of scope: the 7-step "Voice flow" spec only covers a control-WebSocket reconnect, not a client-side WebRTC reconnect mid-session). Flagged here rather than silently ignored; see "Exports for downstream plans" below.
- **The `.sessionError` control message is treated as non-terminal.** Per the landed "voice-control-websocket-client" plan's own design note, `session_error` is deliberately advisory-only and never triggers `onTerminal` — this plan's `handleControlMessage` logs + records it via `state.recordError` without tearing down, matching that contract exactly. No follow-up needed here; documented for completeness.
- **Feature-flag blast radius.** `VoiceSessionPresenter.isTrialVoiceSessionFlowEnabled` is a single `private static let` — flipping it affects every voice session app-wide with no gradual rollout, cohort gating, or server-side kill-switch check on the client side. The pricing spec calls for "server-owned flags for shadow accounting, public trial availability... an emergency AI kill switch" — this plan's local flag is a client-side placeholder for that, not a replacement. A later plan should likely make this flag read a server-delivered value (e.g. from `/api/billing/me`'s snapshot) instead of a hardcoded constant.
- **`ControlWebSocketClient`'s automatic reconnect means a dropped-and-recovered control channel is invisible to `RealtimeVoiceSession`.** Since there's no connection-state signal on this plan's side anymore (by design — see Task 8), a UI element that wants to show "reconnecting..." for the control channel specifically (as opposed to the WebRTC-level `reconnecting(attempt:)` state) has no data to render from. Not a correctness gap (the spec doesn't require this UI), but worth noting if a future design wants it — it would require either widening `ControlSocketConnecting` again or observing `ControlWebSocketClient.latestMessage`'s staleness heuristically.

## Test strategy (deferred per this plan's TDD override)

No new tests are written by this plan. When a follow-up test-alignment pass happens (recommended once the feature flag flips), it should cover at minimum:

- `RealtimeVoiceSession.startTrialVoiceSession`'s four failure branches (`sessionCoordinator.startSession` throws, `client.connect` throws, `providerCallId` returns nil, `sessionCoordinator.registerCall` throws) — each must assert `client.disconnect()` was called (via a new `FakeRealtimeClient.disconnectCalls` check) before the FSM lands in `.failed`, proving no untracked session is left dangling.
- `handleControlMessage`'s per-case dispatch (allowance/ending/error/non-terminal-snapshot) using a fake `ControlSocketConnecting`, and `terminateFromControlSocket`'s teardown-then-fail ordering when `onTerminal` fires.
- `VoiceSessionStartFailure.classify`/`VoiceSessionRegistrationFailure.classify` against every `WorkerErrorCode` constant added in Task 2 (mirrors the existing `KeyFetchFailureTests`-style coverage, if one exists — verify the actual test file name before assuming).
- An end-to-end fake-driven test of the full `startTrialVoiceSession` happy path landing in `.live` with `activeVoiceSession` populated.

## Go/no-go signal

**Ship this plan's code now; ship the *behavior* behind a flag.** Every file this plan touches compiles and passes its existing test suite standalone — there is zero risk to the legacy voice flow, since `sessionCoordinator` defaults to `nil` and `VoiceSessionPresenter.isTrialVoiceSessionFlowEnabled` is hardcoded `false`. Unlike an earlier draft of this plan, **both sibling dependencies (`RealtimeAPIAdapter.providerCallId`, `ControlWebSocketClient`) are real, landed implementations as of this writing** — there is no stub to worry about leaving in place. Recommended flip sequence for `isTrialVoiceSessionFlowEnabled`:

1. Land this plan's Tasks 1–13 and confirm `swift test --package-path Packages/RishiCore` and `swift test --package-path Packages/RishiVoice` both pass clean (Task 14).
2. Run `rg -n "var providerCallId" apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeAPIAdapter.swift` and `rg -n "actor ControlWebSocketClient" apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/ControlWebSocketClient.swift` one more time immediately before flipping the flag, in case either sibling's code has since been reverted or renamed — this plan's Task 10/Task 8 verification steps already do this once, but the flag flip is a separate, later event that deserves its own check.
3. Flip `isTrialVoiceSessionFlowEnabled` to `true` for an internal/TestFlight build first; watch `voice.session.create.failed`/`voice.session.register_call.failed`/`voice.session.control.terminal` log-event rates before a general rollout.

There is no launch-blocking dependency left outside this plan's own code.

---

## Exports for downstream plans

This is plan 16 of 16 in this series. All of its own dependencies had landed by the time it was finalized, so the follow-ups below are refinements, not missing integrations:

- **`INSUFFICIENT_TRIAL_CREDITS` UI is a generic dismiss-only alert, not an upgrade screen.** The "no-card-onboarding-allowance-ui" plan's exhaustion/upgrade screen did not exist when this plan was written (confirmed via `Glob`/`Grep` — no matching plan file or `ExhaustionUpgrade`/`TrialExhausted`/`UpgradeScreen` symbol anywhere in `apps/apple`). `VoiceFailureAlert.PrimaryAction.dismiss` (Task 6) is the deliberate interim behavior for `.sessionStart(.insufficientCredits)` and for the two exhaustion-shaped `sessionTerminated` reasons (`trialCreditsExhausted`, `planVoiceAllowanceExhausted`). Once that screen exists, add a `.upgrade` `PrimaryAction` case carrying (or paired with) a navigation hook, and update `VoiceFailureAlert.primaryAction(for:)`'s two `.dismiss` branches to return `.upgrade` instead; the app layer (likely `VoiceSessionHost.swift`, which already switches on `presenter.failure`) would then route `.upgrade` to that new screen.
- **This plan's own remaining flagged gotcha** (WebRTC-level reconnect not re-registering a call ID — see "Production gotchas" above) should be picked up by whichever plan next touches `RealtimeVoiceSession`'s reconnect code or the ledger's call-ID-acceptance semantics.
- **An app-foreground-triggered `reconnect()` on the control socket is not wired.** `ControlSocketConnecting.reconnect()` exists (Task 8, wrapping the real `ControlWebSocketClient.reconnect()`) and is exposed on the protocol, but nothing in this plan calls it — `ControlWebSocketClient`'s own automatic backoff is sufficient for this plan's scope. A later plan wiring app-lifecycle notifications (e.g. `UIApplication.didBecomeActiveNotification`) into `RealtimeVoiceSession` could call `await controlSocket?.reconnect()` there for a faster resync than the current backoff delay; `RealtimeVoiceSession` would need a small new method exposing that hook, since `controlSocket` itself is private.
- **Test alignment** (see "Test strategy" above) is deferred, matching this entire 16-plan series' TDD override, but is the natural next step once the flag is ready to flip.
