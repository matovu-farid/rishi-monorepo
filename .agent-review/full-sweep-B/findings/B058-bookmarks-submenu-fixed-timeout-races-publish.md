---
id: B058
spec: e2e/menu-bookmarks-submenu.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-bookmarks-submenu.spec.ts` waits `1500ms` raw after clicking
`Bookmarks → Add Bookmark` to bridge the IPC round-trip + DB write +
menu rebuild + re-apply. If the publish path in `src/main/menu/installMenu.ts`
debounces or coalesces rebuild events (likely, since it re-applies the full
menu), 1500ms is either flaky-short under CI load or wastefully long. There
is no event the test awaits — only a wall-clock sleep. This is a
menu-state asynchrony hole: an actual regression where the publish never
fires would not surface as a clear failure, only as flake.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-bookmarks-submenu.spec.ts`
  lines `58-69`
- Failing assertion (today's text):
  ```
  await bookPage.waitForTimeout(1500)
  ...
  expect(labels.some((l) => l !== 'Add Bookmark' ...)).toBe(true)
  ```
- How to run:
  ```
  cd apps/rishi-electron
  for i in 1 2 3; do pnpm test:e2e e2e/menu-bookmarks-submenu.spec.ts \
    || echo "run $i: FAIL"; done
  ```

## Tester Analysis
The bookmarks-publish IPC (referenced indirectly via the click on L58 and
the subsequent menu read on L63) is the single most timing-sensitive seam
in this group. The production contract is: after `addBookmark` resolves,
the Bookmarks submenu re-applies with the new entry. The test should
poll via `expect.poll(() => getApplicationMenu(launched.app).then(...))`
against the predicate on L67-69, with a generous timeout, so that:

1. A genuine regression (publish never fires) fails with a clear poll
   timeout pointing at the missing menu item, not as a vacuous-pass on
   stale menu state.
2. A faster-than-1500ms path passes immediately, shortening test runs.

The current shape masks bugs in the publish path under the timeout. The
production code involved: `src/main/menu/installMenu.ts` (re-apply),
`src/main/ipc/menu.ts` (publish channel), and the bookmark-add handler
that triggers republish. If any of those silently throws but the wall
clock still advances 1500ms, the existing assertion measures the
*previous* menu and may still pass (if a prior bookmark exists in the
DB) or fail with no diagnostic pointing at the publish path.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (static analysis of timing model)
**Reasoning:** The publish chain after `clickMenuItem(['Bookmarks','Add Bookmark'])` is a 4-hop async pipeline: `menu:command` IPC → renderer `addBookmark` handler in `pdf.tsx:339-352` calls `toggleBookmark` (which itself does `bookmarks:list` + `bookmarks:save` IPC roundtrips through `bookmark-storage.ts:93-109`) → `publishBookmarksToMenu` (`bookmark-storage.ts:48-72`, another `bookmarks:list` IPC) → `setMenuContext` IPC → `MenuInstaller.setContext` (`installMenu.ts:17-24`) → `Menu.setApplicationMenu`. The test only sleeps `1500ms` on L61 and has no event to await. While `installMenu.ts` itself has no debounce (just a hash dedupe), the multi-hop IPC chain plus `browser-window-focus` competing handler (`index.ts:191-202`) makes the wall-clock value brittle under CI load and wasteful when fast. The finding correctly identifies a real test-quality hole — but it's not a production bug, it's flake-prone test scaffolding.
**Suggested fix scope:** Replace `waitForTimeout(1500)` on L61 with `expect.poll(() => getApplicationMenu(launched.app).then(m => findMenuItem(m,['Bookmarks'])?.submenu?.map(s=>s.label) ?? [])).toEqual(expect.arrayContaining([expect.stringMatching(/^Page \d+/)]))` with a generous timeout.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
status: fixed
commit: 7c77fd32ad041b86a18f26c6e7159a7aa2b83bdd
notes: Replaced `await bookPage.waitForTimeout(1500)` on L61 with
`expect.poll(...)` that queries the application menu and waits for a real
bookmark entry (anything beyond `Add Bookmark`, `Show All Bookmarks…`, and
parenthesized placeholders) to appear under Bookmarks. Timeout 10s, so a
publish regression times out with a clear diff against the current submenu
labels rather than silently passing on stale state. The combined
`getApplicationMenu + findMenuItem + label` extraction is inlined inside
the poll closure to keep the assertion site self-contained. Typecheck green.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
