# Pilot - Test Review Index

## Wave Status

| Wave | Status | Started | Completed |
|---|---|---|---|
| 0. Setup | done | 2026-05-20 | 2026-05-20 |
| 1. Plan | done | 2026-05-20 | 2026-05-20 |
| 2. Triage | done | 2026-05-20 | 2026-05-20 |
| 3. Reviewer-1 | done | 2026-05-20 | 2026-05-20 |
| 4. Rebuttal | done | 2026-05-20 | 2026-05-20 |
| 5. Tiebreaker | skipped (no rebuts) | | |
| 6. Fix (bugs) | skipped (0 confirmed bugs) | | |
| 7. Mutation check | skipped (no fixes) | | |
| 8. Test-quality triage | done | 2026-05-20 | 2026-05-20 |
| 9. Test-quality fix | done | 2026-05-20 | 2026-05-20 |
| 10. Summary | done | 2026-05-20 | 2026-05-20 |

## Findings

| ID | Spec | Current Stage | Reviewer-1 Outcome | Tiebreaker | Fix Commit | Mutation Passed | Dispatches Used |
|---|---|---|---|---|---|---|---|
| 011 | e2e/azw3-real-import-routing.spec.ts | closed (rejected; substance → practices-audit Wave 8) | REJECT (team-reviewer) | n/a (no rebut) | | | 3 |

## Parity Gaps
See `parity-gaps.md`.

## Practice Violations
See `practices-audit.md`.

## Dispatch Budget
- Soft cap: 60 dispatches for pilot
- Hard per-finding cap: 8 dispatches
- Final global count: 20
  - Planner: 1
  - Triage testers: 4
  - Reviewer-1: 1
  - Rebuttal tester: 1
  - Quality triager: 1
  - Q01-Q06 coders: 6
  - Q01-Q06 code reviewers: 6
- Wave 9 queue: Q01-Q06 (all done, 6/6 approved)

## Test-Quality Fix Outcomes (Wave 9)

| Q-ID | Title | Commit | Reviewer | Notes |
|---|---|---|---|---|
| Q01 | mobi.spec tautological assertions | `32ddeae9` | APPROVE | Replaced self-referential count assertions with iframe-visible + src blob regex |
| Q02 | mobi.spec waitForTimeout | `63525625` | APPROVE | Bogus-id wait → `getByText('Book not found')`; teardown timeout pre-existing |
| Q03 | azw3 test.setTimeout removal | `0b157bf4` | APPROVE | No-op cleanup — playwright.config sets 60s globally. Triage miscall (should have been Type B) |
| Q04 | pdfStore resetParagraphState | `d74f0391` | APPROVE | Added 2 missing field assertions |
| Q05 | epubStore bookOutline contract | `87bc14d0` | APPROVE | Documented "reset preserves outline; subscription clears" |
| Q06 | pdfStore beforeEach getInitialState | `bebde994` | APPROVE | Switched to Zustand `setState(getInitialState(), true)` full-replace |

## Pilot Outcome (2026-05-20)

**Bug findings totals:**
- Filed: 1 (finding 011 — importBook helper masks routing bugs)
- Confirmed by Reviewer-1: 0
- Rejected by Reviewer-1: 1 (tester accepted rejection — substance moved to practices-audit)
- Tiebreaker overturned: 0 (no tiebreakers needed)
- Fixed + mutation-verified: 0 (no fix wave triggered)
- Fixed but mutation FAILED: 0

**Test-quality totals:**
- Type A items filed: 6 (Q01-Q06)
- Type A items fixed: 6
- Type A items abandoned: 0
- Type B items documented (for later): 14

**Parity gaps documented:** ~21 (across 4 specs) — pending follow-up

**Workflow health signals:**
- Reviewer-1 outcomes split: 0% CONFIRM / 100% REJECT (n=1; the lone finding was correctly identified as test-quality, not a bug — small-sample false signal, not a calibration failure)
- Tiebreaker overturn rate: N/A (no tiebreakers ran)
- Per-finding dispatches: median 3, max 3 (cap was 8 — well under)
- Total dispatches: 20 (budget was 60 — used 33%)
- Triage calibration: 1 of 6 Type A items (Q03) should have been Type B → ~17% miscall rate — acceptable

**Recommendation for full sweep: SCALE with adjustments**

The workflow proved sound. The multi-agent dialog mechanic worked cleanly on a borderline case (Tester 3 vs Tester 4 disagreement → Reviewer-1 adjudication → tester accept). Test-quality fix loop produced 6 atomic commits, all approved on first review.

Adjustments to apply to the full sweep:
1. **Scope screening before Wave 2:** the planner should flag `test.skip(...)` specs up front so testers don't waste dispatches looking for bugs in inert tests. The pilot's main bug-hunting surface (warm-restore specs) was skipped — most output landed in parity-gaps.md instead of findings/.
2. **Triager calibration sharpening:** test-quality triager should check project-level config (playwright.config, etc.) before claiming a spec-level setTimeout override has impact (Q03 lesson).
3. **Reviewer alternation only meaningful at scale:** with one finding, the alternation rule didn't get exercised. Will matter more for full sweep.
4. **Pre-existing teardown flakes:** the mobi.spec orphan-BrowserWindow teardown was flagged but not fixed — needs a real test-infra fix that spans tests. Add a "test infrastructure backlog" category in the full sweep.

**Status: PILOT-COMPLETE**
