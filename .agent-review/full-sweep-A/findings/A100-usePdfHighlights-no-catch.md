---
id: A100
spec: apps/rishi-electron/src/renderer/src/hooks/usePdfHighlights.ts
status: fixed
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
parent: A033
---

## Bug Summary
Spawn from A033. `usePdfHighlights.ts` L21-37 had no `.catch` on either
IPC path: the mount/transition `useEffect` (L30 `void getHighlightsForBook(...).then(...)`)
and the imperative `refresh()` (L21-25 bare `await`). A rejected
`window.electron.highlightsList` therefore surfaced as an unhandled
promise rejection in the renderer. Phase A pinned the current behaviour
by installing `unhandledrejection` + `process.on('unhandledRejection')`
swallows in the test so Vitest would stay green; A033's Fix Plan flagged
this as a production defect for follow-up. This finding is that
follow-up.

## Reproduction
- Hook file: `apps/rishi-electron/src/renderer/src/hooks/usePdfHighlights.ts` lines `21-37`
- Test file: `apps/rishi-electron/src/renderer/src/hooks/usePdfHighlights.test.tsx`
- How to run: `pnpm --filter rishi-electron test usePdfHighlights`

## Fix Plan
**Status:** fixed
**Commit:** 6416bd83
**Notes:**
1. RED: strengthened the existing `IPC rejection leaves highlights stable …`
   test to capture `unhandledrejection` events into an array and assert
   `expect(unhandled).toEqual([])`. Removed the Phase A
   `e.preventDefault()` and `process.on('unhandledRejection')` swallows.
   With those gone and the new assertion in place the test failed against
   the unpatched hook (the bare `.then` on L30 raised an unhandled
   rejection).
2. GREEN: wrapped `refresh()` body in `try/catch` and chained `.catch` on
   the effect's promise. Both log via
   `console.error('[usePdfHighlights] …', err)` matching the
   `useHydrateAuth` pattern in the same hooks directory — no project
   logger module exists.
3. VERIFY: `pnpm --filter rishi-electron test usePdfHighlights` → 5/5
   pass without swallow workarounds.
