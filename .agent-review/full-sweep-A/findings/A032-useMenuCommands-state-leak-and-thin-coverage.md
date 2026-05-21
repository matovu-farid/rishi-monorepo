---
id: A032
spec: apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`useMenuCommands.test.ts:10-19` overwrites `window.electron` wholesale in
`beforeEach` and never restores it, then test 3 (`unsubscribes on unmount`,
L35-44) overwrites it AGAIN mid-test with a different stub. The `test-setup.ts`
fixture defined `window.electron` once via `Object.defineProperty(... writable:
true)` at file-load time; the file-scoped `beforeEach` here mutates the live
object reference, so any subsequent test in the same file that *forgets* to
re-stub will silently inherit the previous stub. Today the suite has only 3
tests and `beforeEach` reassigns, so the leak is latent — but adding a 4th test
that does not reassign (e.g. a windowIdentity-filter test) will pick up
test 3's `dispose`/`onMenuCommand` mock instead of test-setup's defaults and
produce a confusing pass/fail. Combined with the plan's observation that
`useMenuCommands` covers only 3 of N MenuCommandHandlers concerns (no
`windowIdentity.kind` filtering, no multi-handler dispatch order, no
"handler throws → listener survives"), the test as written is both
fragile *and* under-tightened.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.test.ts` lines `8-44`
- Failing assertion: none today — finding is about latent fragility +
  coverage gap on a single hook surface
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/useMenuCommands.test.ts`

## Tester Analysis
Two concrete additions are needed:
1. Wrap the global mutation in `beforeEach`/`afterEach` symmetrically, e.g.
   `const original = window.electron; afterEach(() => { window.electron =
   original })`. Without this, parallel-file-isolation in Vitest masks the
   problem only because the file has no other consumers — fragile invariant.
2. Add a `windowIdentity.kind !== 'library'` test: production likely filters
   by window kind before dispatching (the mock seeds `kind: 'library'`
   unconditionally). If the hook does NOT filter and is supposed to,
   this is a real production bug; if it does filter, the test should pin
   it. Either way the current 3-test suite cannot tell.
3. Add a "handler throws synchronously" test — IPC listeners that bubble
   exceptions can de-register the entire bridge. Production behaviour:
   unknown.

Per plan §4 hooks-A entry for this file, "Only 3 tests for 4 listed
MenuCommandHandlers-related concerns. Coverage gap" — promoting it from a
parity-gap to a finding because the state-leak invariant is an active
test-correctness risk, not pure missing-coverage.

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** N/A — production code untouched; suite passes 3/3 runs (durations 269/275/270ms, all 3 tests green) at `useMenuCommands.test.ts`. No flake observed.
**Reasoning:** Production hook `useMenuCommands.ts:5-20` simply registers a callback via `window.electron.onMenuCommand` and returns the dispose fn from `useEffect`; it does not consult `windowIdentity`. That filtering responsibility lives in the main process at `main/index.ts:185-188` (`BrowserWindow.getFocusedWindow().webContents.send('menu:command', cmd)`) — per-window targeting is "focused-window", not renderer-side filter. So the finding's "windowIdentity-filter test would expose a real bug" claim is speculative; there is no current production bug. However, the test-quality observations are valid: (1) the file-scoped `beforeEach` at `useMenuCommands.test.ts:8-19` mutates `window.electron` without symmetric restore, and test 3 (`L37-40`) does a second mid-test overwrite — within this file `beforeEach` masks it, and Vitest's default file isolation prevents cross-file bleed, but the pattern is fragile and would silently break the moment a test in this file is added that doesn't call `renderHook` after the mutation, or if isolation is ever disabled; (2) the suite has zero coverage for "handler throws synchronously → listener still installed" and "multiple handlers / dispatch order", both cheap to add and behaviorally meaningful. Scope is one test file (production code stays put). Fits TEST-QUALITY-A.
**Suggested fix scope (if A or B):** Add symmetric `afterEach` to restore `window.electron`, hoist test-3's stub into the same beforeEach pattern (or use `vi.stubGlobal`), and append two tests: handler-throws and 2-handler dispatch — all inside `useMenuCommands.test.ts`.
