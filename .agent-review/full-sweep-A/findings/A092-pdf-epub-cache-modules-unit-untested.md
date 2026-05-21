---
id: A092
spec: src/renderer/src/services/reader-cache/cache.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`pdf-cache.ts` and `epub-cache.ts` — the two real production consumers of `createReaderCache` and the modules that mount `window.__readerCache.{pdf,epub}` for every e2e warm-restore spec — have zero unit-test coverage. The cache *factory* (`cache.ts`) is well-tested, but the *configured instances* and their **module-init side effects** are not. A regression that changes a config constant (`maxEntries: 3 → 1`), drops the `typeof window !== 'undefined'` guard, or breaks the `w.__readerCache = w.__readerCache ?? {}` coexistence pattern would ship green at the unit level.

## Reproduction
- Test files (missing): `apps/rishi-electron/src/renderer/src/services/reader-cache/pdf-cache.test.ts`, `epub-cache.test.ts`
- How to verify the gap: `ls apps/rishi-electron/src/renderer/src/services/reader-cache/` → only `cache.test.ts` exists.
- How to run (once added): `pnpm --filter rishi-electron test src/renderer/src/services/reader-cache/`

## Tester Analysis
The two modules contain real production logic that `cache.test.ts` cannot reach:

1. **Configuration as contract.** `pdf-cache.ts:9-15` and `epub-cache.ts:18-24` set `maxEntries: 3`, `maxEntryBytes: 50_000_000`, `maxTotalBytes: 150_000_000`. These are the numbers production runs against. A code-review-approved typo (`3` → `1`, `150_000_000` → `15_000_000`) would not fail any test. Pin them with one assertion each.

2. **Module-init side effect.** Both files run a top-level `if (typeof window !== 'undefined')` block that mounts `window.__readerCache.<fmt>`. Three regression vectors:
   - The guard is `typeof window !== 'undefined'`. In happy-dom (the test env per `vitest.config.ts`), `window` exists, so the side effect fires on import. **Confirmed unit-testable.**
   - The init uses `w.__readerCache = w.__readerCache ?? {}` (pdf-cache.ts:25, epub-cache.ts:36) so importing both modules should leave **both** `pdf` and `epub` keys present. Nothing asserts coexistence — a future refactor that hoists `w.__readerCache = {}` (without `?? {}`) would have the second-imported module wipe the first. e2e `epub-warm-restore.spec.ts` would still pass because it only reads `epub`; `pdf` regressions would be invisible.
   - Each diagnostic surface exposes `{ has, size, stats, resetStats }`. If the shape drifts (e.g. someone removes `resetStats` because "it's only used by tests"), e2e helpers fall back to safe defaults (`epub-warm-restore.spec.ts:65` swallows undefined silently) and the warm-restore spec passes by accident on the cold run.

3. **`destroy` wiring.** `pdf-cache.ts:14` passes `(proxy) => proxy.destroy()`; `epub-cache.ts:23` passes `(book) => book.destroy()`. Both are Promise-returning in production. The fire-and-forget `void opts.destroy(...)` in `cache.ts:63` means a rejected destroy is swallowed — but at minimum the unit test for each module should confirm the destroy function is the one being called when `evictPdf`/`evictEpub` runs. This becomes the only place that pins the contract that **the cache, not the viewer, owns destroy**, which is the entire premise of `pdf.tsx:411` / `EpubView.tsx:325` reading `getCachedPdf(...)?.document` without ever calling `.destroy()`.

Minimum useful suite (~20 LOC each):

```ts
// pdf-cache.test.ts
import { describe, it, expect, beforeEach } from 'vitest'

describe('pdf-cache module init', () => {
  beforeEach(async () => {
    vi.resetModules()
    delete (window as any).__readerCache
  })

  it('mounts window.__readerCache.pdf on import', async () => {
    await import('./pdf-cache')
    const w = window as any
    expect(w.__readerCache?.pdf).toBeDefined()
    expect(typeof w.__readerCache.pdf.has).toBe('function')
    expect(typeof w.__readerCache.pdf.size).toBe('function')
    expect(typeof w.__readerCache.pdf.stats).toBe('function')
    expect(typeof w.__readerCache.pdf.resetStats).toBe('function')
  })

  it('coexists with epub-cache without clobbering', async () => {
    await import('./pdf-cache')
    await import('./epub-cache')
    const w = window as any
    expect(w.__readerCache.pdf).toBeDefined()
    expect(w.__readerCache.epub).toBeDefined()
  })
})
```

The "coexists" test is the one that catches the load-order regression no other test can.

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** N/A — no test exists; this is a coverage gap, not a flaky test.
**Reasoning:** All three tester claims verified against source:
- `pdf-cache.ts:9-15` / `epub-cache.ts:18-24` hardcode `maxEntries: 3`, `maxEntryBytes: 50_000_000`, `maxTotalBytes: 150_000_000` and pass `destroy` callbacks — never asserted anywhere.
- `pdf-cache.ts:23-32` and `epub-cache.ts:34-43` run a top-level `if (typeof window !== 'undefined')` side effect using `w.__readerCache = w.__readerCache ?? {}` to coexist. `vitest.config.ts` sets `environment: 'happy-dom'`, so `window` exists at import time — the side effect is unit-testable.
- `grep -r __readerCache` confirms only e2e specs (`epub-warm-restore.spec.ts`, `epub-cache-no-flash.spec.ts`) touch the diagnostic surface; no unit-level guard exists. A load-order regression that dropped `?? {}` would silently break PDF warm-restore (no e2e covers the pdf+epub coexistence path).
- `cache.test.ts` exclusively tests the factory in isolation with a `FakeDoc`; it never imports the two real consumer modules.
Classification is TEST-QUALITY-B (additional coverage warranted, not a production bug). The constants and side-effect coexistence are real contracts that the suite leaves unpinned.
**Suggested fix scope (if A or B):** Add `pdf-cache.test.ts` and `epub-cache.test.ts` (~20 LOC each) using `vi.resetModules()` to assert config-constant pinning, `__readerCache.{pdf,epub}` mount, two-module coexistence, and that `evictPdf`/`evictEpub` invokes the wired `destroy`.

<!-- legacy template fields below; not used by Phase A workflow -->
## Reviewer-1 Verdict (legacy): CONFIRM | REJECT
<append after wave 3>

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
