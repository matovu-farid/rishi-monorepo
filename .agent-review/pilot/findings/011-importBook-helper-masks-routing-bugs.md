---
id: 011
spec: e2e/azw3-real-import-routing.spec.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 3
---

## Bug Summary

The shared e2e helper `importBook` in `e2e/helpers/electron-app.ts` (lines
89-126) hardcodes the caller-supplied `kind` into the `saveBook` payload
instead of using the value returned by the per-format parse IPC. The result:
every e2e test that uses `importBook` will report the "right" kind in the DB
even if the production dispatcher were misrouting the file. This is the
exact mechanism that hid the original AZW3 routing regression (see
`azw3-real-import-routing.spec.ts:18-22`: "The existing e2e tests passed
because the `importBook` helper hardcoded `kind: 'azw3'` into the saveBook
payload, completely bypassing dispatch."). The helper is still wired the
same way today, so the **library of legacy specs that call `importBook` will
continue to silently mask any future routing/dispatch bug for any of the
four formats** — not just AZW3.

This is a *test-infrastructure* defect with production-bug consequences:
the helper does not exercise the IPC path that production code uses, so
production bugs in that path go undetected by the existing suite. The
narrow regression test added in `azw3-real-import-routing.spec.ts` only
covers AZW3 via `importBookViaOpenFile`; MOBI, PDF and EPUB are still
serviced by the lying helper. Wave-1 note confirmed MOBI is symmetrically
affected (`mobi.spec.ts` uses `importBook` with hardcoded `kind: 'mobi'`).

Expected vs actual:
- Expected: `importBook` should call the per-format parse IPC, then persist
  the *parser-returned* `kind` (i.e. mirror what `runImport` does at
  `importer.ts:153` — `kind: bookData.kind`).
- Actual: helper persists `input.kind` (line 114), an untrusted argument
  from the caller. The parser's `kind` is read into `data` at line 107 and
  then discarded.

## Reproduction

- Test file: `apps/rishi-electron/e2e/helpers/electron-app.ts` lines `89-126`
- The masking assertion (proof-by-bug): any spec calling
  `importBook(page, { kind: 'azw3', ... })` will report `kind === 'azw3'`
  in the DB **even if `dispatchFormatExtraction` regressed to call
  `getMobiData` for `.azw3`** — because the helper never calls the
  dispatcher and never reads `data.kind`.
- Demonstrating test (would be added under
  `src/renderer/src/services/book-import/dispatch.test.ts` or as an e2e
  parallel):
  - Stub `getAzw3Data` to return `{ kind: 'mobi', ... }` (simulating the
    historical bug), run `importBook(page, { kind: 'azw3', ... })`, then
    `getBookKind(page, id)`. With the current helper the result is `'azw3'`
    (false negative). With the fix it is `'mobi'`, surfacing the regression.
- How to run: not runnable as a Vitest case until the helper is split into
  a real-pipeline variant; the existing e2e
  `pnpm test:e2e e2e/azw3-real-import-routing.spec.ts` already proves the
  contrast (passes via dispatcher; the old helper would have hidden it).

## Tester Analysis

The defect lives in production-adjacent test code, but the consequence is a
production-quality gap: by parity-with-production, every helper that mocks
a contract is a place where the contract can drift unnoticed.

- The helper's import path (renderer-side `e.saveBook({ kind: input.kind, ... })`)
  is a parallel implementation of `runImport` in
  `src/renderer/src/services/book-import/importer.ts:118-158`. Production uses
  `bookData.kind` (line 153); the helper uses `input.kind` (line 114). They
  must agree, or the test asserts a different contract than the user gets.
- The narrow fix that resolved the AZW3 regression
  (`src/renderer/src/services/book-import/dispatch.ts:53` —
  `format === 'azw3' ⇒ getAzw3Data`) is correct for production but does not
  prevent recurrence in the test layer. Any future change that re-introduces
  format-confusion at the dispatch or extractor layer (e.g. someone wires
  a new `.kfx` extension and accidentally points it at `extractMobiData`,
  which hardcodes `kind: 'mobi'` via `extractKindleData('mobi')` at
  `src/main/ipc/formats.ts:599-606`) would again pass every legacy spec
  using `importBook`.
- Wave-1 explicitly flagged MOBI's helper as the "same bug class". This
  finding documents that the bug class is the *helper*, not any one format.
  Fixing it once benefits PDF/EPUB/MOBI/AZW3 uniformly.
- Production-code citation for the contract that the helper violates:
  - `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts:118-127`
    (parse via dispatcher), `:153` (persist `bookData.kind`).
  - `apps/rishi-electron/src/main/ipc/formats.ts:612-624` (extractor sets
    `kind` from its own param, not its caller's promise).

Recommended remediation (do not implement; capture for the fixer):
1. Change `importBook` so it does not accept `kind` as an input contract;
   instead it derives the parse IPC from the file extension (same switch
   as production) and passes `data.kind` to `saveBook`.
2. Or, remove `importBook` entirely in favor of `importBookViaOpenFile`,
   which already exercises the real pipeline. The cost of the latter is
   slightly slower e2e runs; the benefit is one source of truth.

## Reviewer-1 Verdict: REJECT
**Agent type:** team-reviewer
**Flake check:** N/A — no executable failing test to re-run; this is a structural defect claim.
**Reasoning:** The finding's factual core is accurate — `e2e/helpers/electron-app.ts:114` does persist `input.kind` (caller-supplied) and discards `data.kind` (parser-returned) read at line 107. However, per plan §4.3, a finding requires "a real production code path that produces incorrect user-visible behavior." The defect here lives in test-helper code, not production. Walking the current production pipeline confirms there is no user-visible bug right now: for every supported extension, `extOf` → `formatFor` → `dispatchFormatExtraction` routes to the matching `getXxxData`, and `extractKindleData(filePath, kind)` at `src/main/ipc/formats.ts:612-624` returns the parser's `kind` parameter that already matches the dispatched format (mobi→'mobi', azw3→'azw3'); EPUB and PDF parsers similarly return their own kind. The AZW3 routing regression that originally motivated this helper-suspicion has been fixed in `dispatch.ts:53` and is now guarded by `azw3-real-import-routing.spec.ts` via `importBookViaOpenFile`. The finding's own language — "would continue to silently mask any *future* routing/dispatch bug" and "any *future* change that re-introduces format-confusion" — concedes this is hypothetical-future-regression risk, which §4.3 explicitly maps to `practices-audit.md` (a test-quality issue), not `findings/`. On the Tester 3 vs Tester 4 disagreement, I side with **Tester 4**: the helper is a parallel implementation of the import pipeline that bypasses the dispatcher, which is a real test-infrastructure quality problem worth fixing, but it is not a production bug today. The narrow AZW3 regression spec already pins the behavior the helper would have masked; widening that coverage to MOBI/PDF/EPUB via `importBookViaOpenFile` (parity gap) is the right remediation, captured in the practices/parity buckets rather than as a production-bug finding.
**If REJECT, what would change my mind:** Demonstrate a current production code path where `extractXxxData`/`getBookData`/`getPdfData` returns a `kind` that disagrees with what dispatch would produce for the same extension, such that an end-user importing today gets a misrouted reader. Absent that, this stays a test-infrastructure defect and belongs in `practices-audit.md` (with the MOBI/PDF/EPUB `importBookViaOpenFile` coverage gaps logged in `parity-gaps.md`).

## Tester Rebuttal: ACCEPT-REJECTION
**Reasoning:** Reviewer-1's code reading is accurate and their application of plan §4.3 is principled. The plan is explicit that findings/ requires "a real production code path that produces incorrect user-visible behavior" — and my own finding language ("would continue to silently mask any *future* routing/dispatch bug", "any *future* change that re-introduces format-confusion") conceded this is regression-risk insurance, not a current production defect. I re-walked the dispatch chain in `dispatch.ts:53`, `formats.ts:612-624`, and the EPUB/PDF parsers; for every supported extension today, the parser-returned `kind` matches the dispatched format, so an end-user importing via the production UI gets the correct reader. The helper's parallel-implementation problem is real but lives entirely in test code — it is a test-infrastructure defect with no current user-visible consequence. Per §4.3, that belongs in `practices-audit.md` (with the MOBI/PDF/EPUB `importBookViaOpenFile` coverage gaps in `parity-gaps.md`), exactly as Reviewer-1 directed. Rebutting on "I think the rule should also cover regression-insurance gaps" would be the meta-debate the steel-man rule prohibits. The substantive analysis is preserved in the practices-audit move; no work is lost.
**If REBUT, what evidence the reviewer missed:** N/A — accepting rejection.

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
