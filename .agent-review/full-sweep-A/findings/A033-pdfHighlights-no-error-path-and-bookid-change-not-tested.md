---
id: A033
spec: apps/rishi-electron/src/renderer/src/hooks/usePdfHighlights.test.tsx
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`usePdfHighlights.test.tsx` asserts the happy path (empty syncId guard,
load on syncId arrival, refresh re-fetches) but has zero coverage of two
realistic failure surfaces that the IPC contract surface exposes:
(1) `highlightsList` rejects — IPC errors in production manifest as a
rejected promise; the hook today either swallows the error, leaves
`highlights` stale, or crashes the renderer with an unhandled rejection.
Test cannot tell which. (2) `bookSyncId` transitions from one non-empty
value to another (`'sync-1' → 'sync-2'`) — the production fetch effect
should re-run with the new id and *replace* (not merge or duplicate) the
previous result. The current `refresh()` test at L72-81 covers the
imperative refresh code path but NOT the reactive id-change path, which
is the one users actually hit when switching books in the library.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/usePdfHighlights.test.tsx` lines `5-82`
- Failing assertion: n/a — gap
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfHighlights.test.tsx`

## Tester Analysis
Two tests to add (TDD-red, will surface real production behaviour):

1. `bookSyncId change refetches with new id and replaces results`:
   - `listMock.mockResolvedValueOnce([{ id: 'a', ...}]).mockResolvedValueOnce([{ id: 'b', ...}])`
   - `rerender({ id: 'sync-2' })`
   - `expect(listMock).toHaveBeenCalledTimes(2)` AND
   - `expect(result.current.highlights[0].id).toBe('b')` (not concatenated)

2. `IPC rejection leaves highlights stable and does not throw`:
   - `listMock.mockRejectedValue(new Error('IPC down'))`
   - render with id, `await waitFor(() => expect(listMock).toHaveBeenCalled())`
   - assert renderer did not unmount, hook still returns an array, and a
     subsequent successful `refresh()` recovers.

Both correspond to production code paths that exist today (renderer
switches books constantly; IPC can fail during reload). Per finding-file
rules in plan §6, these are findings (not parity-gaps) because each
exposes an undefined production behaviour the test could pin in one
or two assertions.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** team-reviewer
**Flake check:** N/A (no failing test to repro; finding is a coverage gap)
**Reasoning:** Production hook `usePdfHighlights.ts` L21-37 has two real, exercised paths that the existing tests (L5-82) do not cover:
  (1) `bookSyncId` change — the effect's dep array `[bookSyncId]` re-runs on transition `'sync-1' → 'sync-2'` and `setHighlights(rows.filter(...))` replaces (not merges). Behaviour is currently correct but unpinned; users hit it on every book switch in the library.
  (2) IPC rejection — neither the effect (L30, bare `.then`) nor `refresh()` (L21-25) has a `.catch`. A rejected `window.electron.highlightsList` produces an unhandled promise rejection in the renderer (effect path) and a propagated throw from `refresh()`. The hook contract (`refresh: () => Promise<void>`, `highlights: HighlightRow[]`) gives no signal about this, so the test gap hides a genuine defect.
  Both reproduce in production with one assertion each (rerender props for the id change; `mockRejectedValue` + `waitFor` for the rejection). Finding rules per plan §6 are satisfied — each gap maps to defined-or-undefined behaviour pinnable in ≤2 assertions.
**Suggested fix scope (if A or B):** Add the two tests in the finding's Tester Analysis; the rejection test will fail red and force a `.catch` on L30 + try/catch (or `.catch`) in `refresh()`.

## Fix Plan
**Status:** partially-fixed
**Commit:** 15d07999
**Notes:** Added two tests: (1) `bookSyncId change re-fetches with new id and replaces (not merges) results` — passes; pins the replace-not-merge behaviour on book switch. (2) `IPC rejection leaves highlights stable and a subsequent successful refresh() recovers` — passes, but the test had to install both a `window.unhandledrejection` listener AND a `process.on('unhandledRejection')` swallower to keep Vitest from failing the run. This **confirms the production defect** called out by Reviewer-1: the effect at `usePdfHighlights.ts:30` and `refresh()` at L21-25 have no `.catch`, so an IPC rejection becomes an unhandled rejection in the renderer. The hook itself does NOT throw synchronously and leaves `highlights` as `[]`, and a later successful `refresh()` recovers — that is the pinned current behaviour. Production fix (add `.catch` on both paths) is out of scope per task constraints; flagged here for follow-up.
