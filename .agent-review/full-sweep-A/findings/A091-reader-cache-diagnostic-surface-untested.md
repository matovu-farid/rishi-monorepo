---
id: A091
spec: src/renderer/src/services/reader-cache/cache.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`ReaderCache<T>`'s diagnostic surface (`has`, `size`, `stats`, `resetStats`) is the load-bearing contract behind every e2e warm-restore assertion, yet `cache.test.ts` never exercises any of those four methods. Production e2e specs (`e2e/epub-warm-restore.spec.ts`, `e2e/epub-cache-no-flash.spec.ts`) call these via `window.__readerCache.epub.{has,size,stats,resetStats}(...)`. A regression in any of the four (return-type drift, `stats()` returning the live counter object instead of a copy, `resetStats()` not zeroing both fields, `has()` desynchronized from `get()`) would ship green at the unit level and only surface in CI e2e — exactly the cold/warm split the pilot called out as undercovered.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/services/reader-cache/cache.test.ts` lines `26-204`
- Failing assertion (to add): none of the following names appear in the file:
  - `cache.has(...)`
  - `cache.size(...)`
  - `cache.stats(...)`
  - `cache.resetStats(...)`
- How to run: `pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/cache.test.ts`
- Verify the absence: `grep -nE "\\.(has|size|stats|resetStats)\\(" apps/rishi-electron/src/renderer/src/services/reader-cache/cache.test.ts` returns no hits.

## Tester Analysis
The contract sits in `cache.ts` lines `47-50` (interface) and `148-163` (implementation):

```
has(bookId)        // L148 — entries().has(bookId)
size()             // L152 — entries().size
stats()            // L156 — { ...stats }  (defensive copy)
resetStats()       // L160 — zeros hits and misses
```

Each is consumed unconditionally by e2e helpers:
- `e2e/epub-warm-restore.spec.ts:38` — `w.__readerCache?.epub?.has(bookId) ?? false` (fallback `false` would mask a broken `has`)
- `epub-warm-restore.spec.ts:47` — `size()` (fallback `-1` masks a broken size)
- `epub-warm-restore.spec.ts:56` — `stats()` (fallback `{hits:-1,misses:-1}` masks a broken stats)
- `epub-warm-restore.spec.ts:65` — `resetStats()` (no return value to mask, but a no-op `resetStats` would let cold-run hits leak into the warm-run assertion)

The fallback values in the e2e helpers are the most dangerous part: a refactor that renamed `stats` to `getStats` would not throw — it would silently return `-1`, which `> 0` assertions in the spec would treat as "no hits, no misses" and the test might pass for the wrong reason on the cold run. There is no unit-level guard against this rename, and the e2e doesn't run on every PR.

Specifically, `stats()` returns a fresh object via `{ ...stats }` (L157) precisely so the caller can't mutate internal counters. If a future "optimization" returned `stats` directly, no unit test would catch the aliasing — and the e2e `resetStats` call between cold and warm runs (`epub-warm-restore.spec.ts:65`) would still appear to work because both reads would see zero. This is a contract that exists *because of* the e2e use case and is untested at the layer where contract-drift gets caught.

The pilot explicitly called out "the e2e diagnostic surface contract being implicit" (plan-misc-services.md §2.2). Five direct assertions — one per method, plus `stats` returning a copy not a reference — closes the gap with ~15 LOC.

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** team-reviewer
**Flake check:** N/A (coverage gap, not a flaky test)
**Reasoning:** Confirmed `cache.ts:47-50` declares `has/size/stats/resetStats` as a "Diagnostic surface — used by e2e tests" contract, implemented at `cache.ts:148-163` (notably `stats()` returns `{ ...stats }` defensive copy at L157). Grep over `cache.test.ts` returns zero matches for any of the four method names — verified via `grep -nE "\.(has|size|stats|resetStats)\(" cache.test.ts` (no output). E2E consumers at `e2e/epub-warm-restore.spec.ts:38,47,56,65` and `e2e/epub-cache-no-flash.spec.ts:52` use optional-chained fallbacks (`?? false`, `?? -1`, `?? {hits:-1,misses:-1}`) that would silently mask a rename like `stats` → `getStats`, returning sentinel values that downstream `> 0` assertions could misinterpret. Contract drift (e.g., `stats()` returning the live reference instead of a copy) is unit-testable in ~15 LOC but currently has no guard.
**Suggested fix scope (if A or B):** Add five assertions in cache.test.ts: `has` true/false post-set/evict, `size` reflects entry count, `stats()` increments hits/misses correctly, `stats()` returns a fresh object (mutate result, re-read, expect unchanged), and `resetStats()` zeros both counters.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red -> minimal change -> refactor>
**Status:** fixed
**Commit:** 544e892515f19bdf2a13eec64083bbc428313d6c
**Notes:** Added `describe('createReaderCache — diagnostic surface')` block with 4 contract tests: has() tracks set/evict, size() reflects count, stats() returns defensive copy with correct hit/miss counters (mutating the snapshot must not leak), resetStats() zeros both counters. 17/17 tests pass in cache.test.ts; full suite 1107/1107.

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
**Verdict:** APPROVE
**Findings:** none
- Scope is test-only (single file: `cache.test.ts`); no production code touched.
- All 4 tests assert contracts, not just calls: `has()` true/false across set+evict, `size()` increments and decrements, `stats()` returns correct counters AND verifies defensive-copy semantics by mutating the snapshot and re-reading, `resetStats()` zeros both fields.
- Defensive-copy test directly guards `cache.ts:157` (`return { ...stats }`) — mutating `snapshot.hits = 999` then asserting `cache.stats()` still returns `{hits:1, misses:2}` would fail if the implementation ever returned the live reference. This is the exact contract A093 flagged.
- 17/17 pass in cache.test.ts.
