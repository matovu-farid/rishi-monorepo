# Realtime optimistic End + hold final transcript

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make End feel instant with background end delivery + informational failure; keep the last transcript visible on screen through final flush / while TTS plays.

**Architecture:** Split UI dismiss from ledger `POST …/end`. Local WebRTC/audio teardown runs immediately; end HTTP retries in a presenter-owned background task and surfaces an acknowledge-only alert if all attempts fail. Transcript bridge stops clearing live UI on `isFinal`; it clears only when the next non-empty partial for that role starts.

**Tech Stack:** Swift 6, RishiVoice, VoiceSessionPresenter, UserUsageLedger end route (unchanged).

## Global Constraints

- No cascade / VoiceEngine code.
- Do not remove post-tool `response.create`.
- Registered realtime with `callId` is not auto-orphaned on create — end delivery must retry.
- End-failure alert primary action is **dismiss only** (auto-retry already ran); do not offer “Try again” that starts a new session.
- iOS build gate: `swift test` RishiVoice for touched tests; orchestrator `xcodebuild` before handoff.

---

## Task 1: Hold transcript after final

**Files:**
- Modify: `VoiceTranscriptBridge.swift`
- Modify: `VoiceTranscriptBridgeTests.swift`
- Optional comment: `VoiceSessionView.swift`, `VoiceSessionState.swift`

- [x] **Step 1:** Failing tests — after partials + empty/non-empty final, `partialAssistantTranscript` still equals accumulated text; next non-empty partial clears then shows new text.
- [x] **Step 2:** Implement — on `isFinal`, persist + reset internal buffer; **do not** `clearTranscript`. Before appending a non-empty partial when internal buffer is empty, `clearTranscript` then append.
- [x] **Step 3:** `swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceTranscriptBridge`
- [x] **Step 4:** Commit

---

## Task 2: Optimistic End + background delivery

**Files:**
- Modify: `RealtimeVoiceSession.swift` — re-entry guard; local teardown without awaiting `endSession`; expose session id for delivery (or return handle from `end`)
- Modify: `VoiceSessionPresenter.swift` — `requestEnd`: dismiss first, single-flight, background retry `endSession`, informational failure
- Modify: `VoiceSessionStatus.swift` / `VoiceFailureAlert.swift` (+ tests) — `.sessionEndFailed` → `.dismiss`
- Modify: `SignedInView.swift` / `VoiceSessionHost.swift` — wire `requestEnd`
- Modify: `VoiceSessionAPIClient.swift` — fix orphan-cleanup comment; treat already-terminal / no-active as success if needed
- Docs: `VOICE-CHAT-PIPELINE.md` session end section

- [x] **Step 1:** Add failure reason + alert mapping (dismiss-only)
- [x] **Step 2:** Session local end + presenter delivery with 2–3 retries + backoff
- [x] **Step 3:** Wire host/binding; fix double-end
- [x] **Step 4:** Tests for alert mapping; session end re-entry if present
- [x] **Step 5:** Package tests + commit
- [x] **Step 6:** Docs note

---

## Adversarial notes (pre-landed)

- `guard isPresenting` must not skip delivery after optimistic dismiss.
- End-failure must not call `retry()` / start.
- `noActiveVoiceSession` / already terminal on end → success.
- Empty+final pump flush must remain.
