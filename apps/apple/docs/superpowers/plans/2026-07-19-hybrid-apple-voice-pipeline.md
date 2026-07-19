# Hybrid Apple Voice Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a DEBUG-testable Apple-first Voice Chat path (on-device STT → Foundation Models or cloud nano LLM → AVSpeech) beside OpenAI `gpt-realtime-mini`, with Settings to A/B the engines and force-disable Foundation Models.

**Architecture:** `VoiceEngine` preference lives in **RishiCore** (`appleHybrid` | `openaiRealtimeMini`). DEBUG Settings pick the engine; **Release always forces `openaiRealtimeMini`**. Hybrid `POST /api/voice-sessions` with `engine: "hybrid"` creates the ledger row **and inline-activates** it (no OpenAI mint, no `register-call`). Realtime keeps today’s mint + register-call + hangup path but mints `gpt-realtime-mini`. Hybrid LLM is Foundation Models when available and the DEBUG FM toggle is on; otherwise a **non-persisting** `/api/chat` (`gpt-5-nano`) stream that must **not** go through `RishiChatService.stream` (that path always writes conversation history).

**Tech Stack:** Swift 6 / SwiftUI; `FoundationModels` + `Speech` behind `#available` / `canImport`; `RishiCore` + `RishiVoice` + `RishiSettings`; worker voice-sessions + UserUsageLedger + ledger DO migrations.

## Global Constraints

- Stay on `main`; commit under `apps/apple/Packages/`, `apps/apple/rishi/`, `apps/apple/docs/`, `workers/worker/`, `packages/shared/`. Living plan copy: `apps/apple/docs/superpowers/plans/2026-07-19-hybrid-apple-voice-pipeline.md` (tracked). Mirror under gitignored `docs/superpowers/plans/` optional.
- No emojis in code or commits.
- Swift Testing only for Apple packages.
- Do not replace Readium / StoreKit / AVFoundation — parallel hybrid session beside Realtime.
- Package platforms stay iOS 17 / macOS 14; iOS 26 APIs via availability only.
- Metering remains server-authoritative.
- Engine picker + FM kill switch are `#if DEBUG` UI only.
- Hybrid nano turns also incur normal `/api/chat` COGS **in addition to** voice-interval ledger burns — accepted for v1 (still far cheaper than Realtime audio).

## Product decisions (locked)

| Decision | Choice |
| --- | --- |
| Release runtime engine | Always `openaiRealtimeMini` |
| DEBUG preferred default | `appleHybrid` (resolver falls back if Speech unavailable) |
| Realtime model | `gpt-realtime-mini` |
| Hybrid STT (v1) | SpeechAnalyzer only; else fall back to Realtime Mini |
| Hybrid LLM | Foundation Models if enabled+available; else non-persisting `/api/chat` nano |
| Hybrid TTS (v1) | AVSpeech only |
| Hybrid activate | **Inline in create handler** — never a follow-up RPC, never fake `callId` on `register-call` |
| Hybrid client hangup | **Local teardown only** (same as Realtime today — no new `POST .../end`) |
| A/B | Switch engine between sessions in DEBUG Settings |
| FM kill switch | DEBUG toggle → force cloud nano LLM |

## File map

| File | Responsibility |
| --- | --- |
| `workers/worker/src/realtime/client-secrets.ts` | Mint mini |
| `packages/shared/src/billing/default-rates.ts` | Mini rates |
| `workers/worker/src/durable-objects/user-usage-ledger/schema.ts` | `sessionKind` |
| `workers/worker/drizzle/ledger-do-migrations/` + `migrations.js` | DO SQLite ALTER for `session_kind` |
| `workers/worker/src/durable-objects/voice-session/sql.ts` | Insert/update column writes |
| `workers/worker/src/durable-objects/user-usage-ledger/ledger.ts` | `activateHybridSession` |
| `workers/worker/src/routes/voice-sessions.ts` | Engine branch; inline hybrid activate |
| `RishiCore/.../Endpoints/VoiceSessionsAPI.swift` | Optional `clientSecret`, `engine` |
| `RishiVoice/.../Service/VoiceSessionAPIClient.swift` | `StartedVoiceSession.clientSecret: String?` |
| `RishiCore/.../Voice/VoiceEngine*.swift` | Prefs + resolver |
| `RishiSettings/.../Developer/DeveloperVoiceSection.swift` | DEBUG UI |
| `RishiCore` or `RishiVoice` thin `VoiceChatCompleting` | Non-persisting `/api/chat` |
| `RishiVoice/Hybrid/*` | STT, FM responder, session, TTS |
| `VoiceSessionPresenter.swift` | Routing |
| Docs under `apps/apple/docs/` | Pipeline + A/B runbook |

---

### Task 1: Switch Realtime mint to `gpt-realtime-mini`

**Files:**
- Modify: `workers/worker/src/realtime/client-secrets.ts`
- Modify: `workers/worker/src/realtime-client-secrets.test.ts`
- Modify: `packages/shared/src/billing/default-rates.ts`

- [ ] **Step 1:** Change locking test to expect `"gpt-realtime-mini"`.
- [ ] **Step 2:** `bun test src/realtime-client-secrets.test.ts` — FAIL.
- [ ] **Step 3:** Set `model: "gpt-realtime-mini"` in `buildRealtimeClientSecretsBody`.
- [ ] **Step 4:** Add rates:

```ts
"gpt-realtime-mini": {
  audioInputPer1M: 10.0,
  audioOutputPer1M: 20.0,
  textInputPer1M: 0.6,
  textOutputPer1M: 2.4,
},
```

- [ ] **Step 5:** `bun test src/realtime-client-secrets.test.ts src/billing/realtime-usage.test.ts` — PASS.
- [ ] **Step 6: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(billing): mint Voice Chat on gpt-realtime-mini
EOF
)"
```

---

### Task 2: Ledger migration + inline hybrid activate

**Files:**
- Modify: `workers/worker/src/durable-objects/user-usage-ledger/schema.ts` — `sessionKind: text("session_kind").notNull().default("realtime")`
- Create migration via `cd workers/worker && bun run db:generate:ledger` (or hand-write under `drizzle/ledger-do-migrations/`) and ensure `migrations.js` journal picks it up
- **Required:** add idempotent `ensureSessionKindColumn()` in the ledger constructor (same belt-and-suspenders pattern as `ensureReservationsPoolColumns`) — DO journal-skip must not leave inserts writing a missing column
- Modify: `workers/worker/src/durable-objects/voice-session/sql.ts` — insert/update includes `sessionKind`
- Modify: `ledger.ts` — `createVoiceSession({ sessionKind })`, new `activateHybridSession(rishiSessionId, nonce)`
- Modify: `voice-sessions.ts` — `engine` on body
- Modify: `VoiceSessionsAPI.CreatedVoiceSession` — `clientSecret: String?`, `engine: String`
- Modify: `VoiceSessionAPIClient.StartedVoiceSession` — `clientSecret: String?`, pass `engine`
- Modify realtime call sites in the **same task** so the tree still compiles: unwrap/guard non-nil `clientSecret` on the Realtime path in `RealtimeVoiceSession.swift` (and any tests that construct `StartedVoiceSession` / `CreatedVoiceSession`). Do not leave that for Task 8.
- Tests: `voice-sessions-hybrid.test.ts` + ledger hybrid tests

**Locked contract:**

| | Realtime (`engine` omitted or `"realtime"`) | Hybrid (`engine: "hybrid"`) |
| --- | --- | --- |
| Mint OpenAI secret | Yes | **No** |
| Response `clientSecret` | non-null string | **absent / null** |
| Response `engine` | `"realtime"` | `"hybrid"` |
| Activation | Client `POST /:id/register-call` with real OpenAI `callId` | **`activateHybridSession` called inside create handler before JSON response** |
| `callId` column | set on register | stays `null` |
| First interval alarm | on register-call | on hybrid activate |
| Provider hangup | OpenAI hangup when `callId` set | skip (null `callId`) |
| Client end | local teardown only | local teardown only |

`activateHybridSession` must:
1. Verify single-use nonce (same crypto as `registerCallId`)
2. Require `sessionKind === "hybrid"` and `status === "pending_registration"`
3. Set `status: "active"`, `callRegisteredAt: now`, `nonceUsed: true`, `callId: null`
4. `ensureAlarmAtOrBefore(now + INTERVAL_MS)`
5. Broadcast `allowance_remaining`

**Do not** reuse `register-call` with a synthetic call ID. **Do not** leave hybrid in `pending_registration` for a follow-up RPC.

- [ ] **Step 1: Failing tests** — hybrid create returns null secret; session active with null callId past `REGISTRATION_GRACE_MS`; ticks burn allowance; hangup skips OpenAI; realtime path unchanged.
- [ ] **Step 2: Generate/apply DO migration + implement activate + route inline call**
- [ ] **Step 3:** `bun test` hybrid + ledger + existing voice-sessions tests
- [ ] **Step 4: Update both iOS Codable types** (`CreatedVoiceSession` and `StartedVoiceSession`) **and** fix Realtime unwrap/guard + tests so `swift test --package-path apps/apple/Packages/RishiVoice` and RishiCore voice API tests still PASS
- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(worker): inline-activate hybrid voice sessions without call IDs

Add ledger sessionKind migration and meter cascaded Voice Chat on intervals.
EOF
)"
```

---

### Task 3: VoiceEngine preference in RishiCore

**Files:**
- Create: `RishiCore/Sources/RishiCore/Voice/VoiceEngine.swift`
- Create: `RishiCore/Sources/RishiCore/Voice/VoiceEngineStore.swift`
- Tests: `RishiCoreTests/Voice/VoiceEngineStoreTests.swift`

```swift
public enum VoiceEngine: String, Sendable, CaseIterable {
    case appleHybrid
    case openaiRealtimeMini
}

public protocol VoiceEngineStore: Sendable {
    func preferredEngine() async -> VoiceEngine
    func setPreferredEngine(_ engine: VoiceEngine) async
    func useFoundationModels() async -> Bool
    func setUseFoundationModels(_ value: Bool) async
}

public enum VoiceEngineResolver {
    public static func resolved(
        preferred: VoiceEngine,
        speechAvailable: Bool,
        isDebug: Bool
    ) -> VoiceEngine
}
```

Resolver: Release → always `.openaiRealtimeMini`. DEBUG + hybrid + !speech → `.openaiRealtimeMini`. Else preferred.

Keys: `voice.engine`, `voice.useFoundationModels` (defaults: preferred `.appleHybrid`, FM `true`).

- [ ] Tests for store + resolver matrix → implement → `swift test --package-path apps/apple/Packages/RishiCore --filter VoiceEngine` → commit

```bash
git commit -m "$(cat <<'EOF'
feat(core): add VoiceEngine preference and Release-safe resolver
EOF
)"
```

---

### Task 4: DEBUG Developer Voice Settings

**Files:**
- `RishiSettings/.../UI/Developer/DeveloperVoiceSection.swift`
- `SettingsScreen.swift` (`#if DEBUG`)
- App wiring / `ServiceGraphFactory`

Consumes `any VoiceEngineStore` from RishiCore only. Footer: “DEBUG only. Release builds always use Realtime Mini.”

- [ ] Implement → confirm Release omits section → commit

```bash
git commit -m "$(cat <<'EOF'
feat(settings): DEBUG voice engine and Foundation Models toggles
EOF
)"
```

---

### Task 5: SpeechAnalyzer STT wrapper

**Files:** `RishiVoice/Hybrid/SpeechTranscribing.swift`, `AppleSpeechTranscriber.swift`

```swift
public protocol SpeechTranscribing: Sendable {
    var isAvailable: Bool { get }
    func start() async throws
    func stop() async
    var transcripts: AsyncStream<SpeechTranscriptEvent> { get }
}
```

Use `#available(iOS 26, macOS 26, *)`. Audio session: `.playAndRecord` + `.defaultToSpeaker` (shared with AVSpeech).

- [ ] Availability test → implement → commit

```bash
git commit -m "$(cat <<'EOF'
feat(voice): SpeechAnalyzer wrapper for hybrid Voice Chat STT
EOF
)"
```

---

### Task 6: LLM responders (FM + non-persisting nano)

**Files:**
- `RishiVoice/Hybrid/VoiceLLMResponding.swift`
- `FoundationModelResponder.swift` (`canImport(FoundationModels)` + availability)
- `CloudNanoResponder.swift`
- `HybridLLMRouter.swift`
- **New thin client (pick one, prefer A):**
  - **A (preferred):** `RishiCore` protocol `VoiceChatCompleting` + `WorkerClient` implementation that `POST /api/chat`, parses SSE, **does not** touch conversation stores / dirty sync
  - **B:** Promote a public non-persisting helper inside RishiChat and depend on it from RishiVoice — only if A is awkward

**Forbidden:** calling `RishiChatService.stream` / `ChatService.stream` for hybrid turns (persists chat history).

**Do not** add a hard `RishiChat` dependency to `RishiVoice` unless choosing B.

Router: FM when `useFoundationModels && available`, else cloud nano.

Prompt: short tutor instructions + soft-capped page text + eager on-device RAG snippets; keep FM prompts inside ~4K context.

Note in code comment: nano turns bill as chat usage on the worker **and** the voice session burns interval allowance.

- [ ] Router tests → implement FM + CloudNano via `VoiceChatCompleting` → package tests → commit

```bash
git commit -m "$(cat <<'EOF'
feat(voice): hybrid LLM via Foundation Models or non-persisting nano chat
EOF
)"
```

---

### Task 7: Hybrid TTS (AVSpeech)

**Files:** `HybridSpeaking.swift`, `AVSpeechHybridSpeaker.swift`

`stop()` cancels in-flight utterance for barge-in on new finals.

- [ ] Implement → commit

```bash
git commit -m "$(cat <<'EOF'
feat(voice): AVSpeech playback for hybrid Voice Chat replies
EOF
)"
```

---

### Task 8: HybridVoiceSession + presenter routing

**Files:**
- `HybridVoiceSession.swift`
- `HybridMeteringClient.swift` — start hybrid create (already active), open control WS, **local** tear-down on user end (no HTTP end)
- `VoiceSessionPresenter.swift`, host/UI, `ServiceGraphFactory`

Resolve via `VoiceEngineResolver`. Hybrid turn loop: STT final → stop TTS → RAG → LLM → speak. DEBUG subtitle: engine + `foundation`|`nano`.

**Manual checklist:**
- [ ] Hybrid + FM on / off
- [ ] Realtime Mini path
- [ ] Allowance ticks on both
- [ ] Hybrid survives >15s without register-call
- [ ] Release ignores hybrid preference
- [ ] Hybrid turns do **not** appear in text chat history

- [ ] Implement → test → commit

```bash
git commit -m "$(cat <<'EOF'
feat(voice): route Voice Chat through hybrid or realtime-mini engines
EOF
)"
```

---

### Task 9: Docs

**Files:**
- `apps/apple/docs/VOICE-CHAT-PIPELINE.md`
- `apps/apple/docs/RUNBOOK-VOICE-ENGINE-AB.md`

Include: inline hybrid activate, dual COGS note, no chat persistence, Release force-mini, A/B criteria, v1 limits.

- [ ] Write → commit

```bash
git commit -m "$(cat <<'EOF'
docs(voice): document hybrid Apple path and realtime-mini A/B
EOF
)"
```

---

## Out of scope

- Release engine picker / App Store A/B
- Cloud STT cascade fallback
- Premium TTS for hybrid replies
- Electron hybrid
- PCC LLM tier
- Mid-call engine switch
- New HTTP voice-session end endpoint
- Price/allowance changes

## Self-review

| Requirement | Task |
| --- | --- |
| Mini mint | 1 |
| DO migration + inline hybrid activate | 2 |
| Release-safe resolve | 3, 8 |
| DEBUG Settings + FM kill | 3, 4, 6 |
| SpeechAnalyzer | 5 |
| FM or non-persisting nano | 6 |
| AVSpeech | 7 |
| Routing + A/B | 8 |
| Docs | 9 |

**Order:** 1 → 2 → 3 → 4 → 5 ∥ 6 ∥ 7 → 8 → 9

**Hard gate:** Do not start Task 8 until Task 2 proves hybrid stays `active` past registration grace with `callId == null` and ticks intervals.
