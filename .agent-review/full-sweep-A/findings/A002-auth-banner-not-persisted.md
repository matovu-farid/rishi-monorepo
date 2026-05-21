---
id: A002
spec: apps/rishi-electron/src/renderer/src/stores/authStore.test.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 2
---

## Bug Summary
`useAuthStore.dismissBanner()` sets `bannerDismissed: true` in-memory only —
no localStorage persistence. After a page reload, the store re-initializes
with `bannerDismissed: false`, so the welcome banner re-appears even though
the user clicked "dismiss" in a previous session. Expected: the dismissal
state survives reload (matching the persistence semantics applied to
`welcomeSeen` via `'rishi:welcome-seen'`). Actual: `dismissBanner` writes
nothing to localStorage and `hydrateAuth()` does not restore the flag.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/stores/authStore.test.ts` lines `43-46`
- Failing assertion (to add):
  ```ts
  it('dismissBanner persists across reload-equivalent re-init', () => {
    useAuthStore.getState().dismissBanner()
    // simulate re-init: reset state, then hydrate
    useAuthStore.setState({
      user: null, authHydrated: false, welcomeSeen: false,
      bannerDismissed: false, signInOpen: false
    })
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().bannerDismissed).toBe(true)
  })
  ```
- How to run:
  `pnpm --filter rishi-electron test src/renderer/src/stores/authStore.test.ts -t "dismissBanner persists"`

## Tester Analysis
Production paths:
- `apps/rishi-electron/src/renderer/src/stores/authStore.ts:50` —
  `dismissBanner: () => set({ bannerDismissed: true })` — no localStorage write.
- `apps/rishi-electron/src/renderer/src/stores/authStore.ts:40-48` —
  `hydrateAuth()` only reads `WELCOME_SEEN_KEY`, never anything for the
  banner.
- Contrast with `dismissWelcome` (L52-64) and `setWelcomeSeen` (L66-78):
  both persist via `localStorage.setItem(WELCOME_SEEN_KEY, '1')`.

The asymmetry is structural: `welcomeSeen` is durable, `bannerDismissed` is
ephemeral. If the product intent is "dismiss = until next welcome flow",
the in-memory-only flag is correct — but then why have it in the AuthState
shape at all (it could be local to the banner component)? More plausibly,
either (a) `dismissBanner` should persist, or (b) `bannerDismissed` is
double-bookkeeping with `welcomeSeen`. Both interpretations point to a
real bug — either silent reset on reload, or dead state in the store.
Severity is product-decision dependent; filing for confirmation.

## Reviewer-1 Verdict: INVALID
**Agent type:** feature-dev:code-reviewer (verdict relayed by main thread because agent type lacks Edit tool)
**Flake check:** N/A
**Reasoning:** The alleged bug misreads the two-path design. `dismissBanner()` (authStore.ts:50) is intentionally session-scoped — the durable "never show again" path is `dismissWelcome()` (lines 52-64), which persists `welcomeSeen` via `localStorage.setItem(WELCOME_SEEN_KEY, '1')`. After any reload, `hydrateAuth()` (lines 40-48) restores `welcomeSeen: true` when the key is set, suppressing the banner through the welcome-seen gate — not through `bannerDismissed`. Persisting `bannerDismissed` independently would create an inconsistent state. The tester's own analysis acknowledges "product-decision dependent". The existing test at lines 43-46 correctly validates the in-session contract of `dismissBanner`.
**Suggested fix scope:** N/A

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red -> minimal change -> refactor>

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
<append after wave 7; "Production fix reverted at <SHA-or-stash-id>; test failed as expected. Restored; test passes.">

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
