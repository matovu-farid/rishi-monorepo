---
id: B003
spec: e2e/azw3-render-content.spec.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`azw3-render-content.spec.ts:94` asserts `dataLen > 6000` on the PNG screenshot of the iframe as a proxy for "the page is not all-white." This is a brittle heuristic, not a behavior contract: PNG byte length depends on libpng version, Chromium renderer version, OS font hinting, and the specific glyph density of the fixture page (a 1200x800 page with sparse glyphs can compress well below 6 KB). The threshold was chosen empirically against a single fixture and platform. Flagged as a candidate suspected production-blindspot: if the AZW3 renderer ever silently regresses to "near-blank" (a few stray glyphs but no real layout), this assertion may still pass; conversely it may flake spuriously on CI Linux when font rendering differs. Not necessarily a production bug today, but it's the only pixel-level guard against the original user-reported blank-iframe regression, so its fragility undermines the regression signal.

## Reproduction
- Test file: `apps/rishi-electron/e2e/azw3-render-content.spec.ts` lines `L80-L94`
- Failing assertion (potential): `expect(dataLen, 'iframe screenshot byte length').toBeGreaterThan(6000)`
- How to run: `cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron && pnpm test:e2e e2e/azw3-render-content.spec.ts -g "paints"`

## Tester Analysis
This is borderline between practice violation and production-bug-candidate. Filed as a finding (not just practice audit) because:
1. The comment at L88-93 explicitly acknowledges the heuristic nature ("we don't need decoding") — author knew it was fragile.
2. The test is the *primary* regression guard for the original user bug (blank iframe despite parser succeeding). A weak guard against a real production bug is itself a near-bug.
3. Reviewer-1 should rule whether to (a) keep as practice-audit only, (b) escalate to require pixel sampling via `page.evaluate` + `<canvas>.getImageData()` over a sampled grid, or (c) compare against a reference image with a tolerance.

Production-side: no code change suspected today. The fix lives entirely in the test.

If Reviewer-1 rejects this as "not a production bug, just a test smell," accept rejection and demote to practice-audit only.

## Reviewer-1 Verdict: CONFIRM | REJECT
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

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A (no production bug to validate; finding is test-smell only)
**Reasoning:** `azw3-render-content.spec.ts:94` is purely a test heuristic with no production code path implicated. The finding itself states "Production-side: no code change suspected today. The fix lives entirely in the test." and explicitly offers "demote to practice-audit only." Per reviewer charter, test-quality concerns without a concrete repro of an actual flake or production regression are not bugs. The author's worries are speculative ("may flake spuriously on CI Linux", "if the AZW3 renderer ever silently regresses") with no evidence of a real failure scenario. The spec already has stronger guards (boundingBox L42-45, scrollHeight>400 L63, sandbox tokens L102-106) that would catch a genuine blank-iframe regression independent of the byte-length check.
**Suggested fix scope:** Demote to practice-audit; if pursued, replace L94 with a `<canvas>.getImageData()` sample over the iframe region (no production change).

