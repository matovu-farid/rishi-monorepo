---
id: A099
spec: src/renderer/src/services/reader-cache/cache.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
**Cross-cutting (wildcard).** The renderer-core e2e specs use an "optional-chain with safe fallback" pattern when calling into `window.__readerCache.*` diagnostics — `w.__readerCache?.epub?.has(bookId) ?? false`, `?.size() ?? -1`, `?.stats() ?? { hits: -1, misses: -1 }`. The fallback values exist so the helper doesn't throw when the cache is genuinely absent (initial load, before module init). The side effect: when the diagnostic surface **shape drifts** — a method gets renamed, removed, or returns the wrong type after a refactor — the optional chain returns `undefined`, the `??` clause swaps in the fallback, and the e2e spec sees a deterministic-looking value that may or may not fail the assertion depending on whether the spec compares with `> 0`, `=== true`, or `=== n`. The same pattern appears in any future renderer-core feature that exports a `window.__*` diagnostic. The unit-test layer is the *only* place that can pin the shape contract, and it currently doesn't (see A091/A092).

## Reproduction
- E2e files demonstrating the pattern:
  - `apps/rishi-electron/e2e/epub-warm-restore.spec.ts:38` — `?? false`
  - `epub-warm-restore.spec.ts:47` — `?? -1`
  - `epub-warm-restore.spec.ts:56` — `?? { hits: -1, misses: -1 }`
  - `epub-warm-restore.spec.ts:65` — no fallback (void return), but the spec proceeds as if it ran
  - `e2e/epub-cache-no-flash.spec.ts:50-52` — `?? false`
- Production surface that needs to match: `apps/rishi-electron/src/renderer/src/services/reader-cache/{pdf,epub}-cache.ts:24-32 / 35-43`.

## Tester Analysis
The fallback pattern is *correct* defensive code — without it, a missing-window scenario in CI would throw an evaluation error inside `page.evaluate(...)` and produce a noisy failure. The issue is that the same fallbacks **mask shape regressions**:

| Mutation | Optional chain returns | `??` returns | Spec assertion | Result |
|---|---|---|---|---|
| Rename `has` → `hasBookId` | `undefined` | `false` | `expect(cached).toBe(true)` | spec fails (good) |
| Rename `stats` → `getStats` | `undefined` | `{hits:-1, misses:-1}` | `expect(s.hits).toBeGreaterThan(0)` | spec passes (the `-1` is "greater than 0" is false, but `expect(...).toBeGreaterThanOrEqual(0)` passes silently) |
| Remove `resetStats` | `undefined` (void call) | — | (no assertion on resetStats's return) | cold-run hits leak into warm-run; warm assertion `hits > 0` still passes (false positive) |
| `stats()` returns same object reference instead of `{...stats}` | `{hits: N, misses: M}` (live ref) | (no fallback hit) | comparing two captured snapshots passes because both point at the live counter | warm test passes for the wrong reason |

In other words: **the e2e safety nets degrade silently when the shape drifts, and no unit test currently pins the shape.** This is the cross-cutting concern: any future renderer-core feature that uses a `window.__diagnostic` for e2e verification will inherit the same trap unless we standardize on a unit-level shape check.

Recommendations (filed as a wildcard finding rather than per-area because the rule applies across reader-core, future indexer diagnostics, future connectivity diagnostics, etc.):

1. **Convention: every `window.__*` diagnostic surface gets a unit test that imports the module and asserts the shape.** Specifically: every method exists, has the documented arity, and returns the documented type. ~10 LOC per module.
2. **Convention: e2e helpers throw instead of returning sentinel values when the diagnostic is missing.** Change `?? false` to `?? (() => { throw new Error('readerCache.epub.has missing — shape contract broken') })()` (or equivalent). The unit test catches drift at PR time; the e2e helper catches drift at CI time. Both are needed.
3. **As a meta-rule for the planner index:** any new `window.__*` surface added in this repo should land *with* its unit-level shape test in the same PR. A short note in `apps/rishi-electron/src/renderer/src/services/reader-cache/README.md` (does not exist; could be added) or in the cache.ts module header would document the convention.

This is not a finding against any specific test file's quality — it's a pattern that, if not codified, will recur every time the next renderer-core feature reaches for a `window.__foo` for e2e instrumentation. Filed here per the wildcard authority because no per-area tester would surface it.

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** team-reviewer
**Flake check:** N/A (no concrete failing test — the cited `epub-warm-restore.spec.ts` is `test.skip`'d at line 69, and the pattern claim is a meta-rule about future surfaces, not a present-day flake).
**Reasoning:** The finding does not name a single broken test or a single shape-drift that masked a real regression. Re-reading `apps/rishi-electron/e2e/epub-warm-restore.spec.ts:33-67` and `e2e/epub-cache-no-flash.spec.ts:48-53`, the `?? false / ?? -1 / ?? {hits:-1, misses:-1}` fallbacks are correct defensive code for the legit "diagnostic not yet installed" case (the production surface at `src/renderer/src/services/reader-cache/epub-cache.ts:34-43` is gated on `typeof window !== 'undefined'` and installed at module-eval time). The tester's table at lines 26-31 enumerates *hypothetical* drifts; none are observed today. The remediation is a repo-wide convention ("every `window.__*` diagnostic gets a unit-level shape test; e2e helpers throw instead of returning sentinels") which is correct guidance but is infrastructure work, not a per-finding fix. Per the wildcard-finding rules, this belongs in `test-infra-backlog.md`, not in the wave-6 coder queue.
**Suggested fix scope (if A or B):** Move to `test-infra-backlog.md` as a convention proposal: (1) add a shape-assertion unit test alongside every renderer-side `window.__*` diagnostic surface (starting with `reader-cache/{epub,pdf}-cache.ts`), and (2) replace `?? <sentinel>` in e2e diagnostic helpers with a throwing fallback so shape drift fails loudly at CI time.


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
