# Voice Session Inactivity Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** End Voice Chat sessions (cascade and realtime) after **5 minutes without real user/assistant activity**, hang up OpenAI when a `callId` exists, stop burning interval credits while idle, and keep **create idempotent** so the next start always gets a fresh session.

**Architecture:** Server-authoritative inactivity on `UserUsageLedger`. Persist `lastActivityAt` on `voice_session`. Touch it only on **explicit activity signals** (cascade provider success; control message `{type:"client_activity"}` from audio-driven client pings). Do **not** treat interval ticks, WS connect, snapshots, or teardown `client_ack` as activity. Each `tickActiveSession` checks idle age; until Task 4 ships, enforce **only when `sessionKind === "cascade"`** (not a separate env feature flag). Idle ≥ 5 minutes → `terminateSession(..., "inactivity_timeout")` (OpenAI hangup when `callId` set). Next `create*` stays unblocked via hangup resolution + cascade orphan cleanup. Realtime `end()` must call ledger `endSession` like cascade (fixes today’s orphan burn).

**Tech Stack:** Cloudflare Durable Object SQLite (`UserUsageLedger`), existing voice alarm / hangup path, Hono voice-sessions routes, RishiVoice control WS with a dedicated **activity** message (not reuse of teardown `client_ack`).

## Global Constraints

- Living plan: `apps/apple/docs/superpowers/plans/2026-07-19-voice-session-inactivity-timeout.md`
- Timeout: **exactly 5 minutes** (`INACTIVITY_TIMEOUT_MS = 5 * 60_000`)
- Detection lag: up to one voice interval (~30s) after the 5-minute mark (reuse existing alarm; do not add a second alarm)
- Interval ticks **must not** refresh `lastActivityAt`
- Teardown / `disconnect()` **must not** refresh `lastActivityAt` (do not overload advisory `client_ack`)
- Create must remain idempotent: idle/orphan sessions must not permanently block `POST /api/voice-sessions`
- Cascade: null `callId` → terminate + `hangupStatus=succeeded` immediately
- Realtime: terminate + existing `attemptHangup` / `callOpenAiHangup`
- Reason: `"inactivity_timeout"` (matches `packages/shared` voice-chat)
- Bun for worker commands; Drizzle for DO schema; SQL outside ensure*/migrations limited to ensure ALTER + backfill
- **Atomic ship gate:** Do **not** enable the idle check inside `tickActiveSession` in any production deploy until Task 4 (realtime activity pings + realtime `endSession`) is in the **same** deploy. Local/unit tests may exercise the check behind a test hook. Cascade-only early enable is allowed **only** if gated: `if (row.sessionKind === "cascade")` until Task 4 ships.

## Product decisions (locked)

| Decision | Choice |
| --- | --- |
| Idle window | 5 minutes since `lastActivityAt` |
| Who decides | Server only (`tickActiveSession`) |
| Cascade activity | Touch **after successful** STT/LLM/TTS response (not in `assert*` before work) |
| Realtime activity | Client sends `{type:"client_activity"}` on **user and assistant** transcript/audio progress (partial or final; at least once per speaking turn each direction) |
| Not activity | 30s interval charge; control WS connect; snapshot; allowance broadcast; advisory `client_ack`; `disconnect()` teardown |
| Legacy / migrate live rows | On ensure: backfill with `COALESCE(last_activity_at, updated_at, call_registered_at, created_at)` where `last_activity_at IS NULL` and status live. **Runtime idle age** after seed: use `lastActivityAt` only (required non-null after create/register/ensure); if somehow null, treat as idle immediately rather than falling back to tick-bumped `updatedAt` |
| Next create after timeout | New session UUID; old row terminal; hangup resolved for null callId; realtime may briefly wait hangup reconcile |
| Abuse model | Idle open UI / killed app without end stops burning intervals within ~5–5.5 min |
| Intentional End | Both cascade and realtime call `POST .../end` **before** control disconnect so End does not leave an active ledger row |

## Adversarial invariants (do not regress)

1. Never update `lastActivityAt` inside the interval charge path.
2. Never update `lastActivityAt` from teardown `client_ack` / `disconnect()`.
3. `terminateSession` on inactivity must hang up OpenAI when `callId` is set.
4. Cascade inactivity must set hangup `succeeded` so create is not blocked.
5. Touch must be scoped to the session id in the request/tag (no cross-session refresh).
6. Realtime mid-call must not die from missing pings: ship activity pings **before or with** enabling idle terminate for realtime.
7. Live-row migration must not treat NULL `lastActivityAt` as “idle since register” without backfill.
8. Intentional End must terminal the ledger promptly (not wait for inactivity).

## File map

| File | Responsibility |
| --- | --- |
| `workers/.../voice-session/timing.ts` | `INACTIVITY_TIMEOUT_MS` |
| `workers/.../voice-session/messages.ts` | `"inactivity_timeout"` reason; document `client_activity` control message |
| `workers/.../user-usage-ledger/schema.ts` | `lastActivityAt`; terminal reason enum |
| `workers/.../user-usage-ledger/ledger.ts` | ensure+backfill; seed; `touchVoiceSessionActivity`; idle check (gated); `webSocketMessage` handles `client_activity` only |
| `workers/.../voice-session/sql.ts` | `touchLastActivityAt` helper optional |
| `workers/.../routes/voice-cascade-providers.ts` | Touch **after** successful OpenAI/provider work |
| `apps/apple/.../ControlWebSocketClient.swift` | Send `client_activity` API; keep `client_ack` advisory/teardown-only |
| `apps/apple/.../RealtimeVoiceSession.swift` | Activity pings on user+assistant transcript; `end()` → `endSession` then disconnect |
| `apps/apple/.../CascadedVoiceSession` / metering | Already `endSession`; optional `client_activity` after turn (HTTP touch is primary) |
| `apps/apple/.../ControlMessage.swift` | Decode `inactivity_timeout`; map UI copy |
| Docs | Pipeline + runbook |

---

### Task 1: Schema + ensure/backfill + reason + constant

**Files:** `timing.ts`, `messages.ts`, `schema.ts`, `ledger.ts`

- [x] Add `INACTIVITY_TIMEOUT_MS = 5 * 60_000`
- [x] Add `"inactivity_timeout"` to `VoiceSessionTerminalReason` + schema enum
- [x] Add nullable `lastActivityAt` column
- [x] `ensureLastActivityAtColumn()`:
  1. `PRAGMA table_info` — if `last_activity_at` missing, `ALTER TABLE … ADD last_activity_at integer`
  2. **Idempotent backfill live rows only**, self-guarding COALESCE (must include `last_activity_at` first so re-runs / tick-bumped `updated_at` cannot refresh activity):

```sql
UPDATE voice_session
SET last_activity_at = COALESCE(last_activity_at, updated_at, call_registered_at, created_at)
WHERE status IN ('pending_registration', 'active')
  AND last_activity_at IS NULL;
```

  3. Do **not** run an unconditional UPDATE that sets `last_activity_at` from `updated_at` alone on every DO wake
- [x] Call `ensureLastActivityAtColumn()` from the DO constructor `blockConcurrencyWhile` migrate block next to `ensureSessionKindColumn()` (same pattern)
- [x] Commit: `feat(worker): add voice_session lastActivityAt with live-row backfill`

---

### Task 2: Seed, touch RPC, cascade success touch, idle check (cascade-gated until Task 4)

**Files:** `ledger.ts`, `voice-cascade-providers.ts`, tests

- [x] Seed `lastActivityAt: now` on create cascade / create realtime / register-call / cascade activate
- [x] `touchVoiceSessionActivity(rishiSessionId)` — no-op if missing/terminal; else update that id only
- [x] Cascade routes: after **successful** transcribe/complete/speech, call touch (not inside assert-before-work)
- [x] Implement idle check at top of `tickActiveSession` with an **executable** cascade-only gate until Task 4:

```ts
// After ensure + create/register seed, lastActivityAt must be set.
// Do NOT fall back to updatedAt (interval ticks bump it every 30s).
const last = row.lastActivityAt;
if (last == null || now - last >= INACTIVITY_TIMEOUT_MS) {
  if (row.sessionKind === "cascade") {
    await this.terminateSession(row, "inactivity_timeout", userId, now);
    return;
  }
}
```

- [x] Test: null `lastActivityAt` on cascade does not immortalize via fresh `updatedAt`
- [x] **Ship rule:** In the PR that enables realtime idle terminate, change the gate to apply to all `sessionKind` values in the **same** commit as Task 4 client pings + realtime `endSession`
- [x] Tests: boundary ±1 ms; tick does not touch; failed cascade assert/4xx does not touch; successful cascade touches; terminate null-callId → create unblocked
- [x] Commit: `feat(worker): inactivity timeout for cascade; touch on provider success`

---

### Task 3: Create idempotency + hangup notes

**Files:** tests around `assertNoBlockingLiveSession` / create

- [x] Lock: terminal `inactivity_timeout` + hangup succeeded → create OK
- [x] Lock: active cascade orphan still force-ended on create
- [x] Document: realtime with pending hangup may need one reconcile on create (existing behavior)
- [x] Commit: `test(worker): lock inactivity create idempotency`

---

### Task 4: Client activity message + realtime endSession (required before realtime idle)

**Files:** control WS client + server `webSocketMessage`, `RealtimeVoiceSession`, UI copy

**Mandatory event list for realtime `client_activity`:**
- User transcript progress (partial or final) while session live
- Assistant transcript progress (partial or final) while session live  
  (If only finals exist today, finals are the minimum; do not ship user-only.)

**Mandatory End path:**
- `RealtimeVoiceSession.end()` calls `sessionCoordinator.endSession(rishiSessionId)` **before** `controlSocket.disconnect()` (mirror cascade)
- Cascade: keep `endSession` before or immediately after local teardown; prefer **endSession then disconnect** to avoid any teardown message racing a tick
- `disconnect()` must **not** send a message that touches activity (keep sending advisory `client_ack` only if server ignores it for activity; preferred: stop relying on ack for anything enforcement-related)

**Server:**
- Extend control schema: `z.discriminatedUnion` / `z.union` of `{type:"client_ack"}` | `{type:"client_activity"}`
- Only `client_activity` → `touchVoiceSessionActivity` for the **WebSocket-tagged** `rishiSessionId` (ignore any client-supplied id)
- Update comments that currently say `client_ack` is advisory-only and never enforcement — activity message is the enforcement signal

**UI:**
- Map `inactivity_timeout` → “Voice chat ended due to inactivity.”

- [x] Same deploy: enable realtime idle terminate (remove cascade-only gate)
- [x] Tests: fake socket receives activity on transcript; end calls endSession; server ignores client_ack for lastActivityAt
- [x] Commit: `feat(voice): client_activity pings and realtime endSession for idle timeout`

---

### Task 5: Docs

**Files:** `VOICE-CHAT-PIPELINE.md`, `RUNBOOK-VOICE-ENGINE-AB.md`

- [x] Document 5-minute inactivity, activity signals, OpenAI hangup, create-after-timeout, End vs idle
- [x] Commit: `docs(voice): document 5-minute voice session inactivity timeout`

---

## Manual checklist

- [x] Cascade: silent ≥5.5 min → ends; intervals stop; next start works
- [x] Cascade: speak within window → stays live past 5 min from create
- [x] Cascade: invalid STT body does not extend idle window
- [x] Realtime: conversation with transcripts both ways survives >5 min
- [x] Realtime: silence ≥5.5 min → OpenAI hung up; next start works
- [x] Realtime: tap End → ledger terminal promptly (not +5 min burn)
- [x] Deploy with a live >5 min session mid-rollout → call continues (backfill)
- [x] Simulator kill mid-cascade → next start works

## Self-review

| Requirement | Task |
| --- | --- |
| 5 min idle | 2 (+4 for realtime) |
| OpenAI hangup | 2 `terminateSession` |
| No tick / teardown as activity | 2, 4 |
| Cascade success touch | 2 |
| Create idempotent | 3 |
| Realtime acks + endSession | 4 |
| Docs | 5 |

**Order:** 1 → 2 (cascade-gated) → 3 → 4 (un-gate realtime) → 5.

**Hard gates:**
- No production realtime idle terminate without Task 4 in the same deploy.
- No blind 60s keepalive `client_activity` (defeats abuse prevention).
- No touch on `disconnect()` / advisory `client_ack`.
