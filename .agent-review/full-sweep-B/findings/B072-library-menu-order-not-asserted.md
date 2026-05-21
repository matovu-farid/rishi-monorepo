---
id: B072
spec: e2e/menu-library.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-library.spec.ts` line 9 asserts top-level menu labels with
`expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View',
'Window', 'Help']))`. This contract is satisfied by *any* permutation
of those labels (and by supersets). The expected behavior of a native
application menu is order-sensitive: File must precede Edit, View, and
Window per platform HIG, and Help must be last on macOS so the system
appends Help-menu search. A regression that re-orders entries (e.g.
Window before View, or Help moved to the middle) is a real user-visible
bug that this test would silently accept. Expected: `toEqual([...])`
in the canonical order with an explicit Apple-menu prefix on macOS;
actual: an unordered set assertion.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-library.spec.ts` lines `7-11`
- Failing assertion (current): `expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View', 'Window', 'Help']))` (L9)
- Missing assertion: order-pinned `expect(labels).toEqual([...])`
  matching the platform-specific canonical layout
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/menu-library.spec.ts
  ```

## Tester Analysis
The library-window menu builder (out of scope per plan §1 but
referenced here as the surface) emits a fixed ordering today. The test
was written specifically to lock down the library-window menu shape
versus the reader-window menu shape (note the asymmetric "no Bookmarks
/Reader" assertions on L10-11 — those are correctly negative). The
positive assertion on L9 is the weak link: it documents membership but
not order, leaving the most-likely future regression (a reorder during
a menu refactor) undetected. The plan (`plan-menu-B.md` §2.2 bullet 1)
calls this out explicitly as "Practice violation (loose assertion)".

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (assertion-strength finding, not a flake)
**Reasoning:** `menuBuilder.ts` L140-169 emits a deterministic order: mac `[Rishi, File, Edit, View, (Bookmarks, Reader if book), Window, Help]`; non-mac drops `Rishi`. The library window (`ctx.kind !== 'book'`) collapses to `[File, Edit, View, Window, Help]` + optional `Rishi` prefix on darwin. Current spec L9 uses `expect.arrayContaining` which accepts any permutation and silently passes if Window/Help swap or a refactor reorders. The "platform branching" caveat is real but narrow — only the `Rishi` prefix differs — so an order-pinned assertion gated on `process.platform === 'darwin'` is straightforward and not over-strict. Not BUG (test passes today against correct code; this is a missing guard, not a wrong assertion). Classify B: low-severity assertion weakness that lets a plausible regression slip.
**Suggested fix scope:** Replace L9 with platform-branched `toEqual([...])` pinning the canonical order (mac includes `Rishi` first, Help last).


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
<append after wave 7>

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
