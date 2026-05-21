---
id: B103
spec: e2e/library.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`library.spec.ts:101-118` ("right-click context menu deletes a book")
right-clicks a book row, then clicks the first button named exactly
`"Delete"` and expects the title to disappear. There is no intermediate
assertion that a confirmation dialog appeared. If production code today
deletes immediately on context-menu "Delete" click (no confirm step),
that is a destructive-action-without-confirmation UX violation — a real
production bug. If production code does show a confirm modal, the test
is passing by coincidence because the `getByRole('button', { name:
'Delete' })` happens to match the modal's Confirm button rather than the
context-menu item. Either branch is a defect: bug in prod or false
coverage in the test.

## Reproduction
- Test file: `apps/rishi-electron/e2e/library.spec.ts` lines `101-118`
- Failing assertion: missing — no assertion between right-click (L112)
  and Delete click (L115) that a confirm modal is visible.
- How to run:
  ```
  cd apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/library.spec.ts -g "right-click"
  ```

## Tester Analysis
Book deletion removes the file copy under `getAppDataPath` (see
`importBook` helper L93-94 which writes to that location) plus the
SQLite row plus any reading-position state. There is no undo. A
destructive irreversible action exposed via a single right-click +
unconfirmed button is a regression risk and a UX bug. The reviewer
should:

1. Inspect the context-menu component to determine whether a
   confirmation modal is rendered.
2. If yes: this finding becomes a *test* defect (the test is matching
   the modal's button rather than the context-menu item, which means the
   context-menu Delete entry could be removed entirely and the test
   would still pass against the modal — file as practice violation
   instead).
3. If no: this finding becomes a *production* UX defect — destructive
   delete with no confirmation, especially harmful for users with large
   libraries and accidental right-clicks (trackpad two-finger taps on
   macOS are easy to fire by mistake).

Both branches reduce to a real defect; tester escalates as a finding
rather than a practice note because the prod-bug branch is plausible
and high-severity.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Reviewer-1 Verdict: BUG
**Agent type:** team-reviewer
**Flake check:** N/A (static code inspection of context-menu render path)
**Reasoning:** `FileComponent.tsx:369-384` renders the right-click menu as a single `<button>` whose onClick directly invokes `deleteBookMutation.mutate(...)` (L376-379) with no intermediate confirmation modal. `deleteBookMutation.mutationFn` (L153-159) calls `deleteBook` then `removeBook`/`revokeCachedCoverUrl`/`evictPdf`/`evictEpub` — irreversible, no undo. The e2e test (`library.spec.ts:113-115`) is matching that single Delete button truthfully, so this is the prod-UX branch of the dichotomy: destructive delete with no confirm step, easily mis-fired by trackpad two-finger taps on macOS.
**Suggested fix scope:** Wrap the context-menu Delete onClick in a confirm dialog (e.g., reuse existing modal/AlertDialog) before invoking `deleteBookMutation.mutate`; then update the e2e test to assert the confirm dialog appears and target its Confirm button explicitly.
