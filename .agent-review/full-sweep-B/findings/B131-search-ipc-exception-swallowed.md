---
id: B131
spec: e2e/search.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The `searchBookText IPC accepts a query` test wraps the IPC call in a
`try { ... } catch { return false }` and asserts only `Array.isArray(r)`.
If the IPC handler throws (e.g. invalid bookId, FTS index missing,
permission error, sqlite lock) the test reports `expect(false).toBe(true)`
with **no error context** and the assertion is otherwise tautological: any
array — including `[]` returned from a totally broken/empty search index —
passes. The search subsystem could be silently broken in production
(zero hits for every query) and this test would still go green. There is
no fixture-content assertion that proves the index actually returned a
match for a token known to exist in the EPUB.

## Reproduction
- Test file: `apps/rishi-electron/e2e/search.spec.ts` lines `42-54`
- Failing assertion: `expect(result).toBe(true)` (where `result` is `false`
  only when the IPC throws; an empty result array silently passes)
- How to run:
  ```
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/search.spec.ts -g "searchBookText IPC accepts a query"
  ```

## Tester Analysis
The contract being exercised is `electron.searchBookText(query, bookId) →
Array<Match>`. Two real production-bug classes are hidden:

1. **Silent index failure.** If `searchBookText` is wired to return `[]`
   on any internal error (common defensive pattern in IPC handlers), a
   broken index produces a passing test forever. The fixture is a known
   EPUB (`EPUB_FIXTURE`) and `'the'` is a stop-word certain to appear at
   least once in any English EPUB; the test should assert `r.length > 0`
   against a known-good fixture token.
2. **Lost error visibility.** The `catch { return false }` swallows the
   stack trace. When this test fails in CI, the failure message will be
   the cryptic `Expected: true / Received: false` with no IPC error
   propagated. This violates the "let the throw propagate so the failure
   message is useful" rule (plan §2.8).

Production paths to inspect: `src/main/ipc/search.ts` (or wherever
`searchBookText` is registered) and the EPUB FTS index population path
(post-import). A regression in either would not be caught.

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

## Reviewer-1 Verdict: A
**Agent type:** team-reviewer
**Flake check:** N/A (test-quality issue, not flake)
**Reasoning:** `e2e/search.spec.ts:42-54` wraps the IPC in `try { ... } catch { return false }` and asserts only `Array.isArray(r)`. Confirmed: an empty array (silent index failure) passes; a thrown exception is reduced to `Expected true, Received false` losing the stack — both classes of regression are invisible. No fixture-content assertion proves the FTS index returned matches for a known token.
**Suggested fix scope:** Remove the try/catch, let throws propagate, and assert `r.length > 0` (or a specific match shape) for token `'the'` against `EPUB_FIXTURE`.
