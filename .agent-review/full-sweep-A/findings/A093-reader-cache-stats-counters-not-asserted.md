---
id: A093
spec: src/renderer/src/services/reader-cache/cache.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`ReaderCache.stats()` returns `{hits, misses}` counters that `cache.ts:93-95` increments inside `get()`. The numbers are the only signal `e2e/epub-warm-restore.spec.ts` has to distinguish a warm restore (hit on second open) from a cold reopen (miss on second open). No assertion in `cache.test.ts` ever reads either counter — meaning the entire branch on `cache.ts:91-96` is uncovered behaviorally, and an off-by-one in the counter increments would not fail any unit test.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/services/reader-cache/cache.test.ts` lines `26-204`
- Failing assertion (to add):
  ```ts
  it('increments hits on get-hit and misses on get-miss', () => {
    cache.set(1, { id: 'a' }, makeBytes(10))
    cache.get(1)         // hit
    cache.get(1)         // hit
    cache.get(99)        // miss
    const s = cache.stats()
    expect(s.hits).toBe(2)
    expect(s.misses).toBe(1)
  })

  it('resetStats zeroes both counters', () => {
    cache.set(1, { id: 'a' }, makeBytes(10))
    cache.get(1); cache.get(99)
    cache.resetStats()
    expect(cache.stats()).toEqual({ hits: 0, misses: 0 })
  })
  ```
- How to run: `pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/cache.test.ts -t "increments"`

## Tester Analysis
Code path:

```
cache.ts:89-98  get(bookId) {
  const entry = entries().get(bookId)
  if (entry) {
    entry.lastAccess = Date.now()
    stats.hits++           // L93 — never asserted
  } else {
    stats.misses++         // L95 — never asserted
  }
  return entry
}
```

`stats` is a module-private closure variable (L60). The only way to observe it is via `cache.stats()` (L156) or `cache.resetStats()` (L160). Neither is called anywhere in `cache.test.ts`. The e2e `epub-warm-restore.spec.ts:54-65` is the only consumer of these counters in the entire codebase, and it depends on:

1. `hits` strictly increasing on each cache-hit `get()`.
2. `misses` strictly increasing on each cache-miss `get()`.
3. `resetStats()` zeroing both fields between the cold-run and warm-run halves of the spec.
4. `stats()` returning a fresh object so reading `stats()` then calling another `get()` doesn't retroactively mutate the captured value (the `{ ...stats }` defensive copy at L157).

All four invariants are silently load-bearing for the warm-restore e2e. None are pinned by a unit assertion.

Mutation candidates that would survive `cache.test.ts` today:
- `stats.hits++` → `stats.misses++` (swap counters)
- `stats.hits++` → no-op (remove the line)
- `resetStats` → only zero `hits`, not `misses`
- `stats()` → return `stats` instead of `{ ...stats }` (alias bug)

Any of these would make the e2e flaky or false-passing without any unit-level signal. This is a one-test-file, ~15-LOC fix that directly buys the cold-vs-warm assertion the pilot called the planner's primary surface.

Note: per the plan's §2.1, the planner classifies "stats counters never asserted" as a practice gap. I'm escalating to a finding because the e2e spec actively consumes these counters and the fallback values in the e2e helper (`stats() ?? {hits:-1, misses:-1}`) mean a broken `stats()` produces a misleading-but-not-failing e2e result. That is observable production breakage by the criterion in the template ("concrete production-behavior breakage").

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** team-reviewer
**Flake check:** N/A (not a bug — production code at `cache.ts:88-98,156-163` is correct)
**Reasoning:** Verified `cache.ts:60` declares `stats` as a closure scalar; `get()` at lines 89-98 increments `hits`/`misses` correctly; `stats()` at line 157 returns a defensive copy `{...stats}`; `resetStats()` at 160-163 zeros both. `cache.test.ts` (1-204) never invokes `stats()` or `resetStats()` — confirmed via full file read. The four invariants the tester lists (hits+1 on hit, misses+1 on miss, resetStats zeros both, stats() returns a fresh object) are public-interface contracts (`ReaderCache<T>` interface at cache.ts:39-51) and are wired through `epub-cache.ts:40-41` and `pdf-cache.ts:29-30`. The mutation candidates listed (swap counters, drop a line, partial reset, alias return) would all silently survive the current unit suite. Note: the sole consumer `e2e/epub-warm-restore.spec.ts:69` is currently `test.skip` pending Phase 3 window-split rework, which lowers urgency but doesn't change the gap — the surface is still exported, the planner-cited e2e is meant to be reactivated, and other future consumers (telemetry/debug) would inherit the unpinned behavior. Classifying as TEST-QUALITY-A rather than B because the surface is part of the documented public API (interface lines 43-50) and the missing assertions block the only behavioral signal that would catch counter-arithmetic regressions.
**Suggested fix scope (if A or B):** Add the two ~10-LOC tests the finding proposes (hit/miss increment, resetStats zeros both) plus one assertion that `stats()` returns a fresh object (mutate returned value, re-read, expect unchanged) — single test file, no production change.

<!-- placeholder retained for protocol -->
<!-- append after wave 3 -->

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
