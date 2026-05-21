---
id: NNN
spec: e2e/<spec-name>.spec.ts
status: open
created: YYYY-MM-DD
reviewer1_agent_type: team-reviewer | feature-dev:code-reviewer
dispatches_used: 0
---

## Bug Summary
<one paragraph: what's wrong, where, expected vs actual>

## Reproduction
- Test file: `<exact/path/to/spec.ts>` lines `<L1-L2>`
- Failing assertion: `<paste the assertion>`
- How to run: `<exact command>`

## Tester Analysis
<why this is a production bug, not a test problem; cite production code paths>

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
