---
id: B086
spec: e2e/ai-chat.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`e2e/ai-chat.spec.ts` only covers (a) launcher visibility and (b) the premium
gate dialog for an unauthenticated user. The signed-in mic-permission paths —
`navigator.permissions.query({name:'microphone'})` and the
`navigator.mediaDevices.getUserMedia(...)` denial / prompt / granted branches —
are entirely uncovered. Per `project_macos_mic_entitlements.md`, real mic
acquisition requires a signed build, so the actual `getUserMedia` resolution
cannot be exercised in CI — but the *handling* (UI state when permission is
`denied` or `prompt`, error toast / fallback dialog when `getUserMedia`
rejects) is renderer-side JS and is testable by stubbing `navigator.permissions`
and `navigator.mediaDevices.getUserMedia` in `page.addInitScript`. The current
spec exercises zero authenticated branches, so a regression that silently
swallows mic denial would ship green.

## Reproduction
- Test file: `apps/rishi-electron/e2e/ai-chat.spec.ts` lines `41-59`
- Failing assertion: none — there is no test for "Start voice chat" after
  injecting a fake authenticated user (the pattern used at
  `read-aloud-from-selection.spec.ts:70-81`).
- How to run: `pnpm test:e2e e2e/ai-chat.spec.ts` (the current 3 tests pass;
  no signed-in test exists to fail).

## Tester Analysis
The voice-chat orb gates user-facing behavior on two checks: `requireAuth`
and mic permission. Only the first is covered. Production code paths that go
unverified:
- Signed-in click → `getUserMedia` rejected with `NotAllowedError` (denied)
- Signed-in click → `getUserMedia` rejected with `NotFoundError` (no device)
- Signed-in click → `permissions.query` returns `prompt` → user-facing
  preflight UI (if any) before `getUserMedia` is invoked.

Each of these has a distinct UX contract (toast vs dialog vs silent no-op),
and a regression in any of them would not be caught by either spec in scope.
The cross-platform implication is amplified by `project_macos_mic_entitlements.md`:
a build that loses the mic entitlement (rebuilt without the entitlements plist
or codesigned with the wrong identity) would manifest exactly as
`getUserMedia` rejection at runtime — the path that has zero coverage.

The spec also relies on `.first()` on `[aria-label="Start voice chat"]` (L42,
48, 51), which suggests multiple matching nodes (e.g., portal + inline). If a
future refactor removes the duplicate, `.first()` keeps tests green even if
the user-clickable node disappears. This is a secondary concern but should be
addressed alongside the mic-permission gap (use a more specific selector and
drop `.first()`).

## Recommended additions
1. `test('signed-in user with mic denied surfaces an error UI')` — stub
   `navigator.mediaDevices.getUserMedia` via `page.addInitScript` to reject
   with `DOMException('NotAllowedError')`, click the orb, assert the
   user-visible error UI (toast, dialog, or aria-live region).
2. `test('signed-in user with no mic device surfaces a device-missing UI')` —
   reject with `NotFoundError`.
3. Audit `closeOverlays` in `helpers/electron-app.ts` for dialog-content
   dismissal so test 2 leaving the premium dialog open does not poison test 3.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (gap, no failing test)
**Reasoning:** `ai-chat.spec.ts:41-59` only exercises (a) launcher visibility and (b) the unauth premium dialog; no signed-in branch runs `activate()`. `activation-program.ts:307-323` calls `deps.media.getUserMedia` and `mapMicError` (lines 85-92) emits `MicDeniedError` for `NotAllowedError`/`NotFoundError`, which `errors.ts:41-42` and `service.ts:29` map to a distinct `'mic_denied'` chat status — a user-facing branch with zero e2e coverage. Production `media.getUserMedia` at `services/index.ts:299` calls real `navigator.mediaDevices.getUserMedia`, so the recommended `page.addInitScript` stub is feasible. Gap is real but a coverage-extension (B), not a live bug; existing unit tests in `service.test.ts` cover the error mapping at the service layer.
**Suggested fix scope:** Add signed-in e2e tests that stub `navigator.mediaDevices.getUserMedia` to reject with `NotAllowedError`/`NotFoundError` and assert the `mic_denied` UI surface, plus harden `closeOverlays` for dialog-content dismissal.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
