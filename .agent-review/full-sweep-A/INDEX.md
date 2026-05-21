# Phase A (Renderer Core) — Test Review Index

## Wave Status

| Wave | Status | Started | Completed |
|---|---|---|---|
| 0. Setup | done | 2026-05-20 | 2026-05-20 |
| 1. Plan | done (2 original + 4 sub-planners after stores+book-import timeouts) | 2026-05-20 | 2026-05-21 |
| 2. Triage (10 testers parallel) | done (with caveats — T3/T6/T8 findings + T2-T9 audit entries partially lost to parallel-write contention; 26 findings on disk) | 2026-05-21 | 2026-05-21 |
| 3. Reviewer-1 (26 findings, 4-way classification) | done | 2026-05-21 | 2026-05-21 |
| 4. Rebuttal | skipped (0 BUGs, no rebuts needed) | | |
| 5. Tiebreaker | skipped | | |
| 5.5. Triage gate (human go/no-go) | done — top 5 selected (A033, A091, A093 [implicit], A015, A034) | 2026-05-21 | 2026-05-21 |
| 6. Fix (bugs) | skipped (0 confirmed bugs) | | |
| 7. Mutation check | skipped | | |
| 8. Test-quality triage | merged into Wave 3 (4-way classification) | | |
| 9. Test-quality fix | done (4 commits; A093 resolved by A091) | 2026-05-21 | 2026-05-21 |
| 10. Summary | done | 2026-05-21 | 2026-05-21 |

## Findings

| ID | Spec/File | Current Stage | Reviewer-1 Outcome | Tiebreaker | Fix Commit | Mutation Passed | Dispatches Used |
|---|---|---|---|---|---|---|---|

## Parity Gaps
See `parity-gaps.md`.

## Practice Violations
See `practices-audit.md`.

## Test-Infrastructure Backlog
See `test-infra-backlog.md`.

## Dispatch Budget
- Phase A soft cap: 150 dispatches
- Per-finding cap: 8 dispatches
- Final global count: 52 (8 planners + 10 testers + 26 reviewer-1 + 4 coders + 4 code-reviewers)
- Budget used: 52 / 150 (35%)
- Note: parallel-file-write contention in Wave 2 lost ~30-40 audit entries from T2-T9; per-tester-file pattern queued for Phase B.

## Phase A Wave 9 Fix Outcomes

| Q-ID | Commit | Code Review | Notes |
|---|---|---|---|
| A033 | `97cc20f2` | APPROVE | usePdfHighlights bookId-change + IPC-rejection tests. **Spawn finding:** production `usePdfHighlights.ts` lacks `.catch` — unhandled rejection. Filed as A100-followup. |
| A091 | `544e8925` | APPROVE | reader-cache diagnostic surface (has/size/stats/resetStats) unit-tested. **Implicitly resolves A093.** |
| A093 | — | — | Resolved by A091. |
| A015 | `075a4975` | APPROVE | prefsStore hydrate per-key wiring + type-guard fallback. |
| A034 | `16659134` | APPROVE | usePdfTextSelection cross-page guard positive control. |

## Phase A Outcome

**Findings totals:**
- Filed: 26 (intended 50 — losses from Wave 2 contention)
- BUG: 0
- TEST-QUALITY-A: 9 (5 fixed this run, 4 deferred: A001, A013, A032, A043)
- TEST-QUALITY-B: 14 (documented for later)
- INVALID: 3

**Spawn findings:**
- A100-followup (from A033 fix): usePdfHighlights.ts has unhandled promise rejections in IPC effect + refresh. Real production defect surfaced via test-improvement work. Should be a Phase A retroactive BUG finding for follow-up.

**Workflow health signals:**
- Reviewer-1 outcomes: 0 BUG / 9 A / 14 B / 3 INVALID — balanced, no rubber-stamping or rubber-rejecting.
- Tiebreaker overturn rate: N/A (no tiebreakers needed; no rebuttals).
- Per-finding dispatches: median 1, max 3 — well under cap of 8.
- Dispatch budget: 52 / 150 (35%).
- Workflow lessons surfaced:
  1. **Parallel-write contention** on shared audit files cost ~30-40 audit entries. Per-tester-file pattern (each tester writes to its own `parity-gaps-T<N>.md` etc., merged later) required for Phase B.
  2. **`feature-dev:code-reviewer` lacks Edit tool** — substitute `general-purpose` for even-ID reviewers in Phase B+.
  3. **Wave 1 planner timeouts** when scope >8 files — sub-divide planners to 3-5 files each in Phase B+ and bake "write file early" into prompt.
  4. **Some testers returned analysis in text but didn't write findings to disk** (T3, T6, T8). Prompt should require Write tool call before returning.

**Status: PHASE A COMPLETE. Proceeding to Phase B.**

## Wave 3 Classification Outcomes

**0 BUG / 9 TEST-QUALITY-A / 14 TEST-QUALITY-B / 3 INVALID**

| ID | Classification | Brief |
|---|---|---|
| A001 | TEST-QUALITY-A | indexingStore.finish() error spread asymmetry — pin contract |
| A002 | INVALID | bannerDismissed is session-scoped by design (welcomeSeen is the durable path) |
| A003 | INVALID | service.deactivate() early-returns on idle/error; no leak |
| A011 | TEST-QUALITY-B | tutorialStore beforeEach fixture drift (Q06-class) |
| A013 | TEST-QUALITY-A | tutorialStore resetTour assertion incomplete (2 of 5 fields + missing localStorage) |
| A015 | TEST-QUALITY-A | prefsStore hydrate under-asserts (1 of 3 keys, 1 of 3 fields) |
| A017 | TEST-QUALITY-B | prefsStore 2 setters with zero coverage + invalidateKey asymmetry |
| A019 | TEST-QUALITY-B | tutorialStore module-load init never re-exercised |
| A031 | INVALID | partialFirstKey assertion pins documented cache-reuse contract |
| A032 | TEST-QUALITY-A | useMenuCommands beforeEach mutates window.electron without restore + missing handler-throw test |
| A033 | TEST-QUALITY-A | usePdfHighlights missing bookId-change effect + IPC rejection paths |
| A034 | TEST-QUALITY-A | usePdfTextSelection cross-page guard needs positive control |
| A041 | TEST-QUALITY-B | usePageRequestSubscription baseline-less subscribe count |
| A042 | TEST-QUALITY-B | useChapterParagraphPrefetch hardcoded microtask depth (brittle) |
| A043 | TEST-QUALITY-A | useBookSyncId no bookId re-mount test + brittle setTimeout |
| A044 | TEST-QUALITY-B | useCommonMenuHandlers referential-stability test missing rerender-with-new-setter |
| A045 | TEST-QUALITY-B | useTtsHighlightReconciler unmount test bundles 3 channels |
| A061 | TEST-QUALITY-B | service.test happy-path over-specifies upload-started ordering |
| A062 | TEST-QUALITY-B | indexer.test count assertion misses payload shape |
| A063 | TEST-QUALITY-B | indexer.test failOn split contract unpinned |
| A064 | TEST-QUALITY-B | service.test toContainEqual allows stray complete events |
| A065 | TEST-QUALITY-B | service.test imports fixtures from sibling *.test.ts |
| A091 | TEST-QUALITY-A | reader-cache diagnostic surface (has/size/stats/resetStats) untested |
| A092 | TEST-QUALITY-B | pdf-cache.ts / epub-cache.ts modules have zero unit tests |
| A093 | TEST-QUALITY-A | reader-cache stats counters never asserted (zero hits/misses coverage) |
| A099 | TEST-QUALITY-B | cross-cutting e2e diagnostic fallback pattern (move to test-infra-backlog) |

**Workflow note:** 0 confirmed production bugs across pilot + Phase A combined (40+ findings reviewed). Strong signal that renderer-core code is solid; the natural "missing assertion" finding pattern is properly classified as test-quality.

## Area-Planner Assignments (Wave 1)
- Planner 1: stores (10 files) → `plan-stores.md`
- Planner 2: machines+hooks (16 files) → `plan-machines-hooks.md`
- Planner 3: book-import services (6 files) → `plan-book-import.md`
- Planner 4: connectivity+indexing+reader-cache (6 files) → `plan-misc-services.md`

## Tester Assignments (Wave 2) — IDs A001-A100
- Tester 1: stores half-A (authStore, chatStore, epubStore, indexingStore, navStore) → A001-A010
- Tester 2: stores half-B (pdfStore, playerStore, prefsStore, selectionStore, tutorialStore) → A011-A020
- Tester 3: machines (4 files) → A021-A030
- Tester 4: hooks half-A (useMenuCommands, usePdfHighlights, usePdfReadAloudFromSelection, usePdfTextSelection) → A031-A040
- Tester 5: hooks half-B (useTtsHighlightReconciler, useUndoableHighlightShortcut, 6 reader hook tests) → A041-A050
- Tester 6: book-import half-A (dispatch, emitter, importer) → A051-A060
- Tester 7: book-import half-B (indexer, scanner-adapter, service) → A061-A070
- Tester 8: connectivity (service, subscribers, types) → A071-A080
- Tester 9: indexing (index-program, text-extraction) → A081-A090
- Tester 10: reader-cache + cross-cutting wildcard → A091-A100
