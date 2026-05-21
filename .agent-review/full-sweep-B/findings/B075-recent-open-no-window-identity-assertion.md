---
id: B075
spec: e2e/menu-recent.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 0
---

## Bug Summary
`menu-recent.spec.ts` lines 48-51 verify that clicking File > Open
Recent > Recent A opens *a* new window
(`expect(launched.app.windows().length).toBeGreaterThan(before)`), but
does not verify that the new window is showing the correct book. A bug
where the Open Recent handler opens *any* book (the most-recent one
globally, the first in the DB, a hard-coded book id) or where it
opens the library window again would still increment the window count
and pass this test. Expected: assert the newly-opened window's URL
contains `/books/<a.id>`; actual: only the count delta is checked.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-recent.spec.ts` lines `48-51`
- Failing assertion (current): `expect(launched.app.windows().length).toBeGreaterThan(before)` (L51)
- Missing assertion: identify the new window
  (`launched.app.windows()` minus the pre-click snapshot), poll its
  URL, and assert it includes `/books/${a.id}` (or whatever route
  shape the reader uses)
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/menu-recent.spec.ts
  ```

## Tester Analysis
The whole point of Open Recent is that clicking a specific entry opens
*that specific book*. Asserting only "a window appeared" reduces the
test to a smoke test of the Open-Recent click pathway. The plan
(`plan-menu-B.md` §2.3 bullet 6) flags this as a weak-assertion
practice violation. The fix is local to this test — snapshot
`launched.app.windows()` before the click, diff after, then call
`.url()` on the new window inside an `expect.poll(...)` to handle the
load latency that the current `waitForTimeout(1800)` is papering over.
This also incidentally closes the door on the related parity gap
(currently in `parity-gaps-B-T6.md`) where opening Recent never
verifies it actually loaded the imported book versus some default
landing route.

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
<append after wave 7>

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
