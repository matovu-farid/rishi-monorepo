---
id: B087
spec: e2e/ai-chat.spec.ts (and e2e/tts-page-navigation.spec.ts)
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The documented contract in
`docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md`
requires that when voice chat is activated during TTS playback, TTS pauses
(preserving its position) and resumes after voice chat ends. No test in the
four specs in scope covers either direction of this cross-feature
interaction. `ai-chat.spec.ts` exercises only the launcher / premium gate;
`tts-page-navigation.spec.ts` exercises only TTS in isolation. A regression
where voice chat fails to pause TTS — or where TTS fails to resume after
voice chat — would ship green.

## Reproduction
- Test files:
  - `apps/rishi-electron/e2e/ai-chat.spec.ts` (3 tests, 0 cover TTS state)
  - `apps/rishi-electron/e2e/tts-page-navigation.spec.ts` (12 tests, 0
    invoke `[aria-label="Start voice chat"]`)
- Failing assertion: none — no test exists that sequences PLAY (TTS) → click
  "Start voice chat" → assert `playerStore.playingState` transitioned to
  `paused.*` and `audioElement.paused === true`.
- How to run: N/A.

## Tester Analysis
The spec at
`docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md`
defines a multi-store handshake (player machine + voice chat session) that is
exactly the seam where state-machine integration bugs cluster. Both stores
already expose test hooks (`__rishi.playerStore`, `__rishi.audioElement`,
mocked TTS via `installSilentMockTts`); a cross-feature test is cheap to
write and the absence of one means a future refactor of either store can
silently break the documented invariant. Because the mock TTS service
returns immediately and the voice chat session can be exercised via the same
launcher button used in `ai-chat.spec.ts`, no real network is required.

Concrete tests that should exist:
1. PLAY → wait `playing` → click `[aria-label="Start voice chat"]` (with
   injected fake auth user, per `read-aloud-from-selection.spec.ts:70-81`
   pattern) → assert `playerStore.playingState` starts with `paused` and
   `audioElement.paused === true` within 1s.
2. End the voice chat session → assert TTS resumes to `playing` and
   `audioElement.currentTime` is within ε of where it paused (preserved
   position).
3. Reverse direction: voice chat active → click TTS Play → assert
   user-facing UX (block / queue / interrupt — whichever the spec dictates).

This is a parity gap relative to the documented design intent, recorded
here so the implementation team knows the cross-feature contract is
unverified at the E2E layer.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A (no failing test exists)
**Reasoning:** Finding is grounded in `docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md` (dated today, in-flight on `feat/migrate-to-ai-sdk`), which itself says "Files touched (only these four)" — all unit-level (`playerMachine.ts/test.ts`, `chatStore.ts/test.ts`). The plan does not require E2E coverage; the contract is being TDD'd at the machine/store layer. Tester explicitly notes "Failing assertion: none — no test exists" and labels it a "parity gap relative to the documented design intent". That is future-spec scoping, not a regression in shipped behavior, and is out-of-scope for a full-sweep bug review.
**Suggested fix scope:** None — defer; if E2E coverage is desired, file it against the plan's follow-up, not as a sweep finding.
