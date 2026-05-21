---
id: B101
spec: e2e/auth.spec.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`auth.spec.ts` asserts two different selectors for the same intent: line 20
locates `text=Sign In` (capital I) and line 30 locates `text=Sign in`
(lowercase i). Playwright `text=` matchers are case-sensitive on exact
substring matches, so at most one of these is the real UI string — the
other passes only by coincidence (e.g., a different element bearing the
same casing), passes vacuously, or worked once and rotted. Either way the
auth surface contract is under-specified: the test cannot tell us which
casing the renderer emits, and a future copy change to align casing
across screens will silently break one of these assertions.

## Reproduction
- Test file: `apps/rishi-electron/e2e/auth.spec.ts` lines `15-31`
- Failing assertion: see L20 `text=Sign In` vs L30 `text=Sign in`
- How to run:
  ```
  cd apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/auth.spec.ts
  ```

## Tester Analysis
The Sign In affordance is the only auth entry the desktop app exposes
(per `feedback_redis_polling_auth.md` + `project_electron_deeplink_auth.md`
the deep-link OAuth handoff is what the user clicks through). The string
the user reads is part of the production contract for that affordance.
Two specs disagreeing on the casing means one of the following is true in
production code:

1. The library landing page renders "Sign In" while the welcome modal
   renders "Sign in" — i.e., inconsistent capitalization across the auth
   surface (UX bug, low severity but real).
2. Only one casing exists and the other selector matches some unrelated
   element (e.g., a settings link, a paragraph copy fragment). In that
   case at least one of the two assertions is providing zero coverage.

Either branch is a production-relevant defect that the tests, as
currently written, fail to surface and instead paper over. The reviewer
should grep the renderer for both literals to determine which branch
applies and either fix the copy or strengthen the selectors to
`getByRole('button', { name: /sign in/i })` so the casing inconsistency
is exposed rather than absorbed.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A (test-smell finding, not a flaky-test claim)
**Reasoning:** Finding's mechanical premise is wrong. Playwright's unquoted `text=` engine is case-insensitive substring matching (only quoted `text="..."` is case-sensitive exact). Both `text=Sign In` (L20) and `text=Sign in` (L30) match the same "Sign in" elements rendered by `WelcomeModal.tsx:29`, `SignInBanner.tsx:35`, and `PremiumFeatureDialog.tsx:71` — grep confirms zero occurrences of "Sign In" (capital I) in `src/renderer/src`. The inconsistency is cosmetic test-style drift, not "passes only by coincidence" and not a production contract gap. No UX bug, no vacuous assertion.
**Suggested fix scope:** Optional polish — normalize both lines to `getByRole('button', { name: /sign in/i })` for clarity; not a blocker.
