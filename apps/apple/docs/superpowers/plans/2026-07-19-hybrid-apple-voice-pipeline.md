# Cascaded Voice Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove a cascaded Voice Chat pipeline (STT → LLM → TTS) beside OpenAI Realtime, then replace cascade components one at a time. Phase 1 is **OpenAI-only cascade**. Phase 2 swaps components.

**Architecture:** DEBUG `VoiceEngine` in RishiCore: `openaiCascade` | `openaiRealtimeMini`. Release always forces `openaiRealtimeMini`. Cascade sessions use ledger `sessionKind: "cascade"` with **inline activate** (no Realtime mint / no `register-call`). Cascade STT/LLM/TTS go through **new voice-scoped worker routes** that (a) require an active cascade session, (b) do **not** call `reserveTts` / narration metering, (c) do **not** use `requireActiveSubscription` (trial credit users must work — same as today’s voice-sessions). Realtime path keeps WebRTC and mints `gpt-realtime-mini`.

**Tech Stack:** OpenAI `gpt-4o-mini-transcribe`, `gpt-5-nano`, `gpt-4o-mini-tts`; RishiVoice cascade FSM + local mic capture; later Speech / FoundationModels / AVSpeech.

## Phases (locked)

### Phase 1 — OpenAI cascade (test the pipeline)

| Piece | Model | Transport |
| --- | --- | --- |
| STT | `gpt-4o-mini-transcribe` | `POST /api/voice-sessions/:id/cascade/transcribe` |
| LLM | `gpt-5-nano` | `POST /api/voice-sessions/:id/cascade/complete` (SSE or JSON text) |
| TTS | `gpt-4o-mini-tts` | `POST /api/voice-sessions/:id/cascade/speech` |
| Control | ledger 30s intervals | existing `GET /api/voice-sessions/:id/control` |
| A/B | Cascade vs Realtime Mini | DEBUG Settings |

**Do not** reuse `POST /api/audio/speech` for cascade replies — that route calls `ledger.reserveTts` and would burn **narration** allowance on top of Voice Chat intervals.

**Do not** reuse `POST /api/audio/transcribe` as-is — it is **Deepgram-only** today.

**Do not** reuse `POST /api/chat` / `POST /api/text/completions` for cascade LLM — both use `requireActiveSubscription`, which blocks no-card trial users who can still start voice sessions.

**Exit criteria:** DEBUG build completes speak → transcript → answer → hear reply; allowance ticks; no text-chat history rows; trial-credit user can complete a turn; Realtime Mini still works.

### Phase 2 — Replace components (after Phase 1 exit)

1. STT → Apple `SpeechAnalyzer` (fallback OpenAI cascade STT)
2. LLM → Foundation Models + DEBUG FM toggle (fallback nano)
3. TTS → AVSpeech option (fallback cascade OpenAI TTS)

Same FSM; swap protocol implementations only.

## Global Constraints

- Living plan: `apps/apple/docs/superpowers/plans/2026-07-19-hybrid-apple-voice-pipeline.md`
- No emojis; Swift Testing; parallel path beside Realtime
- iOS 17 / macOS 14 floors; iOS 26 only in Phase 2 behind availability
- Metering server-authoritative via Voice Chat intervals for cascade wall-clock; cascade OpenAI calls still Stripe-meter as stt/chat/tts usage for observability but **must not** debit narration seconds
- Engine picker `#if DEBUG` only
- **Forbidden:** `RishiChatService.stream` for cascade LLM

## Product decisions (locked)

| Decision | Choice |
| --- | --- |
| Release runtime | Always `openaiRealtimeMini` |
| DEBUG default | `openaiCascade` |
| Realtime model | `gpt-realtime-mini` |
| Phase 1 models | OpenAI STT + nano + mini-tts (table above) |
| Cascade activate | Inline in create when `engine: "cascade"` |
| Client hangup | Local teardown only |
| Phase 1 endpointing | Silence-based: **800ms** silence after speech → final; **min 400ms** speech; **max 30s** utterance; then auto-restart listen after TTS (unless user ended) |
| Mic audio for STT | **16 kHz mono WAV** (`audio/wav`) uploaded as base64 JSON like existing transcribe body shape |
| Cascade TTS voice | Default `marin` (same allow-list as `/api/audio/speech`) |

## Adversarial invariants (do not regress)

1. Inline `activateCascadeSession` — never fake `callId` on `register-call`; grace (~10s) must not kill cascade.
2. DO migration + **required** `ensureSessionKindColumn()`.
3. `clientSecret: String?` on **both** `CreatedVoiceSession` and `StartedVoiceSession`; Realtime unwrap **same task**.
4. `VoiceEngine` in **RishiCore**.
5. Cascade provider routes verify `sessionKind === "cascade"` + `status === "active"` + ownership; reject otherwise.
6. Cascade TTS **never** calls `reserveTts`.
7. Cascade LLM/STT/TTS routes: `requireAuth` only + active cascade session check — **no** `requireActiveSubscription`.
8. `activateCascadeSession` **must** mirror `registerCallId` alarm side-effects: after `status=active` / `callId=null`, call `ensureAlarmAtOrBefore(now + INTERVAL_MS)`. **Forbidden:** leaving the create-time `REGISTRATION_GRACE_MS` alarm as the next fire (first voice interval would charge at ~10s instead of ~30s).

## File map (Phase 1)

| File | Responsibility |
| --- | --- |
| `client-secrets.ts` / rates | Mini mint |
| Ledger schema + `drizzle/ledger-do-migrations/` + `ensureSessionKindColumn` | `session_kind` |
| `voice-session/sql.ts`, `ledger.ts` | `activateCascadeSession` |
| `routes/voice-sessions.ts` | create branch + cascade subroutes |
| `RishiCore` VoiceEngine + VoiceSessionsAPI + cascade endpoint types | Prefs + wire |
| `RishiVoice` client + `Cascade/*` | Mic, STT/LLM/TTS clients, FSM |
| `RishiSettings` DeveloperVoiceSection | DEBUG picker |
| Docs | Pipeline + A/B |

---

# Phase 1 tasks

### Task 1: Switch Realtime mint to `gpt-realtime-mini`

**Files:** `workers/worker/src/realtime/client-secrets.ts`, `realtime-client-secrets.test.ts`, `packages/shared/src/billing/default-rates.ts`

- [ ] Test expects `"gpt-realtime-mini"`
- [ ] Set mint model; add rate row (audio in/out 10/20, text 0.6/2.4)
- [ ] `bun test src/realtime-client-secrets.test.ts src/billing/realtime-usage.test.ts`
- [ ] Commit: `feat(billing): mint Voice Chat on gpt-realtime-mini`

---

### Task 2: Ledger migration + inline cascade activate

**Files:** schema, `bun run db:generate:ledger`, **required** `ensureSessionKindColumn()`, `voice-session/sql.ts`, `ledger.ts`, `voice-sessions.ts`, `CreatedVoiceSession`, `StartedVoiceSession`, Realtime unwrap in `RealtimeVoiceSession` (+ tests)

**Contract:**

| | Realtime | Cascade (`engine: "cascade"`) |
| --- | --- | --- |
| Mint secret | Yes | No |
| `clientSecret` | non-null | null |
| Activation | `register-call` | **`activateCascadeSession` inside create** |
| `callId` | set | null |
| Interval start | on register | on cascade activate via `ensureAlarmAtOrBefore(now + INTERVAL_MS)` |
| Hangup provider | if callId | skip |
| Client end | local | local |

- [ ] Tests: active past grace; **first interval tick ≥25s after activate** (not ~10s); ticks burn voice allowance; realtime unchanged; iOS packages compile
- [ ] Commit: `feat(worker): inline-activate cascade voice sessions without call IDs`

---

### Task 3: VoiceEngine preference (RishiCore)

```swift
public enum VoiceEngine: String, Sendable, CaseIterable {
    case openaiCascade
    case openaiRealtimeMini
}
```

Release → always mini. DEBUG → preferred (default cascade). No FM toggles in Phase 1.

- [ ] Tests → commit: `feat(core): add VoiceEngine preference and Release-safe resolver`

---

### Task 4: DEBUG engine picker

Cascade (OpenAI) / Realtime Mini. Footer: Release always Realtime Mini.

- [ ] Commit: `feat(settings): DEBUG picker for cascade vs realtime-mini`

---

### Task 5: Worker cascade provider routes (STT + LLM + TTS)

**Why a dedicated task:** Phase 1 fails if agents bolt onto Deepgram transcribe, narration-metered speech, or subscription-gated chat.

**Files:**
- Create: `workers/worker/src/routes/voice-cascade-providers.ts` (mounted under voice-sessions)
- Tests: `voice-cascade-providers.test.ts`
- Rates: Phase 1 may Stripe-meter cascade LLM/TTS with existing `chat` / `tts` meter types. **Do not** invent an `stt` RateCard row in Phase 1 — skip `meterFromContext` for cascade STT or log-only until a real STT rate type exists.

**Shared guard for all three routes:**
1. `requireAuth`
2. Load live session for user; require `rishiSessionId` match, `sessionKind === "cascade"`, `status === "active"`
3. Else 404/409 with stable error codes

**`POST /api/voice-sessions/:id/cascade/transcribe`**
- Body: `{ audio: base64, mime_type: "audio/wav" }` (same shape as today’s transcribe endpoint)
- Call OpenAI transcriptions API with `model: "gpt-4o-mini-transcribe"`
- Return `{ text: string }`
- Stripe-meter: Phase 1 skip STT `meterFromContext` (no `stt` rate type yet); log bytes/model for debug
- Max audio bytes: **2 MiB** (reject larger)

**`POST /api/voice-sessions/:id/cascade/complete`**
- Body: `{ query: string, page_text?: string, active_paragraph_text?: string, rag_snippets?: string[], language?: string }`
- `generateText` / streamText with `gpt-5-nano`, `store: false`
- System prompt: short book tutor + soft-capped page/rag context (reuse soft-cap constant from shared voice-chat)
- Return JSON `{ text: string }` for Phase 1 simplicity (SSE optional later)
- Meter as chat usage; **no** `requireActiveSubscription`

**`POST /api/voice-sessions/:id/cascade/speech`**
- Body: `{ text, voice?, speed? }` — same validation clamps as `/api/audio/speech`
- Call `openai.audio.speech.create` with `gpt-4o-mini-tts`
- **Must not** call `ledger.reserveTts` / commit narration
- May still use TTS R2 cache (cache hit = no OpenAI call); cache writes OK
- Return audio bytes or SSE events matching existing speech response_mode if cheap to reuse; otherwise raw MP3 + `Content-Type: audio/mpeg` for Phase 1
- Meter OpenAI TTS usage for observability only

- [ ] Failing route tests (active cascade OK; realtime session ID rejected; no session rejected; speech does not invoke reserveTts spy)
- [ ] Implement
- [ ] Commit: `feat(worker): cascade STT/LLM/TTS routes scoped to active voice sessions`

---

### Task 6: iOS mic capture + OpenAI STT client

**Files:**
- `RishiVoice/Cascade/SpeechTranscribing.swift`
- `RishiVoice/Cascade/CascadeMicCapture.swift` (AVAudioEngine tap → 16 kHz mono PCM → WAV)
- `RishiVoice/Cascade/OpenAISpeechTranscriber.swift`
- `RishiCore` cascade transcribe endpoint Codable

**Endpointing (locked):**
- Ring-buffer / running RMS silence detector
- After ≥400ms of speech, **800ms** continuous silence → finalize utterance
- Hard cap **30s** → force finalize
- Upload WAV via cascade transcribe route; emit `SpeechTranscriptEvent(isFinal: true)`
- Ignore finals with empty/whitespace text
- Audio session: `.playAndRecord` + `.defaultToSpeaker` (shared with TTS playback)

- [ ] Unit-test silence detector with synthetic samples where feasible
- [ ] Commit: `feat(voice): mic capture and OpenAI STT for cascade Voice Chat`

---

### Task 7: Non-persisting cascade LLM client

**Files:** `VoiceLLMResponding.swift`, `OpenAINanoResponder.swift`, cascade complete endpoint in RishiCore

Calls Task 5 complete route with page text + eager on-device RAG snippets. **Forbidden:** `RishiChatService.stream`.

- [ ] Commit: `feat(voice): cascade gpt-5-nano client without chat persistence`

---

### Task 8: Cascade OpenAI TTS speaker

**Files:** `CascadeSpeaking.swift`, `OpenAITTSCascadeSpeaker.swift`

Calls Task 5 speech route (not `/api/audio/speech`). Reuse RishiAudio MP3 decode/playback if practical. `stop()` cancels in-flight audio for barge-in.

- [ ] Commit: `feat(voice): cascade gpt-4o-mini-tts speaker without narration debit`

---

### Task 9: CascadedVoiceSession + presenter routing

**Files:** `CascadedVoiceSession.swift`, `CascadeMeteringClient.swift` (create+control WS; local end), `VoiceSessionPresenter`, DI

Loop: start cascade → listen → on final → stop TTS → RAG → LLM → speak → listen again until session_ended / user end.

DEBUG subtitle: `cascade` | `realtime-mini`.

**Manual checklist:**
- [ ] Full cascade turn (paid + trial-credit account)
- [ ] Realtime Mini works
- [ ] Allowance ticks; narration seconds **unchanged** after cascade TTS turns
- [ ] Survives >15s without register-call
- [ ] Release ignores cascade preference
- [ ] No new rows in text chat history

- [ ] Commit: `feat(voice): route Voice Chat through OpenAI cascade or realtime-mini`

---

### Task 10: Phase 1 docs + exit notes

`VOICE-CHAT-PIPELINE.md` + `RUNBOOK-VOICE-ENGINE-AB.md`: models, cascade routes, metering rules (voice intervals yes / narration no), A/B criteria, Phase 2 order.

- [ ] Commit: `docs(voice): document OpenAI cascade vs realtime-mini A/B`

---

# Phase 2 tasks (after Phase 1 exit)

### Task 11: STT → SpeechAnalyzer
### Task 12: LLM → Foundation Models + DEBUG kill switch
### Task 13: TTS → AVSpeech option
### Task 14: Phase 2 docs / recommended defaults

---

## Out of scope

- Release engine picker
- Electron cascade
- PCC LLM
- Mid-call engine switch
- New HTTP session end
- Price/allowance changes
- Replacing Realtime entirely
- Using Deepgram for Phase 1 baseline

## Self-review

| Requirement | Task |
| --- | --- |
| Mini mint | 1 |
| Cascade activate + migration | 2 |
| Engine prefs + DEBUG UI | 3, 4 |
| Worker cascade STT/LLM/TTS (no narration / no sub-gate) | 5 |
| Mic + STT client | 6 |
| LLM + TTS clients | 7, 8 |
| Session routing + A/B | 9 |
| Docs | 10 |

**Order:** 1 → 2 → 3 → 4 → 5 → 6 ∥ 7 ∥ 8 → 9 → 10. Then Phase 2.

**Hard gates:**
- No Task 9 until Task 2 proves cascade stays active past grace with null callId.
- No Task 6–8 clients until Task 5 routes exist and tests prove speech skips `reserveTts`.
- No Phase 2 until Phase 1 exit criteria pass (including trial-credit turn + narration unchanged).
