---
id: A001
spec: apps/rishi-electron/src/renderer/src/stores/indexingStore.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 2
---

## Bug Summary
`useIndexingStore.finish(bookId)` transitions an entry to `status: 'done'` but
does NOT clear a previously-set `error` field. After a retry path
(`start -> error -> start -> ...advance -> finish`), the entry surfaces as
`{ status: 'done', error: '<stale message>' }`, so any UI that renders
`entry.error` regardless of status will display a failure tooltip on a book
that successfully finished indexing. Expected: `finish()` clears `error`.
Actual: `error` is preserved via the `{ ...entry, status: 'done' }` spread.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/stores/indexingStore.test.ts` lines `28-35`
- Failing assertion (to add):
  ```ts
  it('finish() clears any prior error after a retry', () => {
    const s = useIndexingStore.getState()
    s.start(7, 3)
    s.error(7, 'embedding failed')
    s.start(7, 3) // retry
    s.advance(7); s.advance(7); s.advance(7)
    s.finish(7)
    const entry = useIndexingStore.getState().byBookId[7]
    expect(entry.status).toBe('done')
    expect(entry.error).toBeUndefined() // currently 'embedding failed'
  })
  ```
  Note: `start()` at `indexingStore.ts:27-33` also fails to clear `error`
  because it constructs a fresh object literal — wait, it actually does
  (it discards prior entry and writes `{ done: 0, total, status: 'running' }`
  with no `error` key). The bug surfaces purely through `finish()` after a
  retry path where `error()` is re-called between `start()` and `finish()`,
  or where `error()` is fired mid-run and a subsequent `finish()` is called
  without re-`start()`-ing.
- How to run:
  `pnpm --filter rishi-electron test src/renderer/src/stores/indexingStore.test.ts -t "finish() clears any prior error"`

## Tester Analysis
Production path at `apps/rishi-electron/src/renderer/src/stores/indexingStore.ts:45-55`:
```ts
finish: (bookId) =>
  set((state) => {
    const entry = state.byBookId[bookId] as IndexingEntry | undefined
    if (!entry) return state
    return {
      byBookId: {
        ...state.byBookId,
        [bookId]: { ...entry, done: entry.total, status: 'done' }
      }
    }
  }),
```
`{ ...entry, ... }` retains the optional `error?: string` field from the
prior `error()` call. Contrast with `error()` at L57-66 which deliberately
preserves done/total via spread but writes `status: 'error'` and `error:
message`. The asymmetry is a real bug: a transient failure followed by a
successful retry leaves `error` set on a `'done'` entry. Any consumer that
checks `entry.error` rather than `entry.status === 'error'` will mis-render.

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** team-reviewer
**Flake check:** N/A — no failing test claimed; finding proposes a new assertion.
**Reasoning:** The asymmetry between `finish()` (indexingStore.ts:45-55) and `error()` (L57-66) is real — `finish()` spreads `...entry` and preserves the optional `error` field, so an entry can end up `{ status: 'done', error: '<stale>' }` after `start -> error -> finish`. However, I grepped every consumer of `useIndexingStore` and `byBookId` in apps/rishi-electron/src (pdf.tsx:561-595 is the sole writer; nothing reads `entry.error` anywhere in the renderer). There is no UI surface today that renders `entry.error` independent of `entry.status`, so the "failure tooltip on a successfully-indexed book" scenario in the Bug Summary is hypothetical, not currently user-visible. The store's public selectors (`getStatus`, `isReady`, `progress`) all key off `status`/`done`/`total` and never expose `error`. This is a latent invariant gap worth pinning down with a regression test before some future consumer trips over it, but it does not meet the BUG bar (current user-visible production bug).
**Suggested fix scope (if A or B):** Add the proposed "finish() clears any prior error after a retry" test to indexingStore.test.ts and have `finish()` write `error: undefined` (or destructure-omit) — one production line + one test, one file each.

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
