---
id: B102
spec: e2e/import.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
`import.spec.ts:57-64` asserts `expect(['ok', 'warn']).toContain(result)`
for `electron.checkFileSize(PDF_FIXTURE, 'pdf')`. The production
`checkFileSize` contract returns one of `'ok' | 'warn' | 'error'` (the
gate that drives the large-file confirmation UI per
`2026-04-23-large-file-handling.md`). Asserting `['ok','warn']` collapses
the only meaningful failure signal — `'error'` — into the only excluded
case. Worse, if the IPC ever starts returning anything else (`null`,
`undefined`, a numeric byte count, a thrown rejection serialized to
`{ error: ... }`), the test fails opaquely rather than catching the
real regression. A small fixture should always return exactly `'ok'`;
encoding `['ok','warn']` admits the warn-band for a known-small file,
which is the bug the size-band logic is supposed to prevent.

## Reproduction
- Test file: `apps/rishi-electron/e2e/import.spec.ts` lines `57-64`
- Failing assertion: `expect(['ok', 'warn']).toContain(result)`
- How to run:
  ```
  cd apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/import.spec.ts -g "checkFileSize"
  ```

## Tester Analysis
The large-file handling design (see plan §2.2 reference) defines three
bands — `ok` (<warn-threshold), `warn` (between warn and hard limit),
`error` (>hard limit). The fixture used here is the bundled small PDF
(`PDF_FIXTURE`), well below the warn band. The only correct assertion is
`expect(result).toBe('ok')`. By accepting `'warn'` as a valid outcome,
the test would silently pass if the size thresholds regressed by an order
of magnitude — exactly the regression the size-band machinery exists to
catch. This is a contract-coverage hole rooted in the test, but the
production code path it should be defending (the warn/error gate) is
load-bearing for import UX, so the gap is production-relevant.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (static test-coverage gap, not a flake)
**Reasoning:** Verified `src/main/ipc/fs.ts:30-44` — `checkFileSize` returns `'ok' | 'warn' | 'blocked'` (the finding says `'error'`, but the type at `src/preload/types.ts:248` and `src/renderer/src/lib/api.ts:144` confirms `FileSizeCheck = 'ok' | 'warn' | 'blocked'`). PDF warn threshold is `200 MB` (`fs.ts:23`); `PDF_FIXTURE` is `~920 KB` (`e2e/fixtures/test-book.pdf`), three orders of magnitude under warn. The assertion at `e2e/import.spec.ts:63` `expect(['ok','warn']).toContain(result)` would silently pass even if size thresholds regressed ~200x, defeating the gate's coverage. Real but low-severity (test-only, no runtime impact) — B-tier.
**Suggested fix scope:** Change line 63 to `expect(result).toBe('ok')` and (optionally) add a separate fixture-driven case asserting `'warn'`/`'blocked'` against synthetic sized inputs.
