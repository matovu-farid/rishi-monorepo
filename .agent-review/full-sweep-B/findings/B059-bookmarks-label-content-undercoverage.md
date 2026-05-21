---
id: B059
spec: e2e/menu-bookmarks-submenu.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The Bookmarks-submenu spec asserts only that *some* label exists which is
not `Add Bookmark`, not `Show All Bookmarks…`, and does not start with
`(`. It does not validate the label's *content* (e.g. `Page N`, chapter
title, or any positive format pattern). A regression that produces a
non-empty but malformed label (e.g. `"undefined"`, `"NaN"`, the raw JSON
of the bookmark row, or a single space) passes the test. This is a
classic too-weak assertion masking format-specific bugs in the bookmark
label formatter.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-bookmarks-submenu.spec.ts`
  lines `65-69`
- Failing assertion (today's text):
  ```
  expect(
    labels.some((l) => l !== 'Add Bookmark'
      && l !== 'Show All Bookmarks…' && !l.startsWith('('))
  ).toBe(true)
  ```
- How to run:
  `cd apps/rishi-electron && pnpm test:e2e e2e/menu-bookmarks-submenu.spec.ts`

## Tester Analysis
The bookmark-label format is a production contract (it appears in the
application menu and is the only user-visible hint of *which* bookmark
they're about to jump to). The spec should pin it down — at minimum a
regex such as `/^Page \d+/` for the PDF fixture, or an assertion that
the label includes the page number returned by the addBookmark IPC.
Today, a refactor that replaces `formatBookmarkLabel(bookmark)` with
`String(bookmark.id)` passes the assertion. That is a user-facing
regression with zero test signal.

This is undercoverage of the menu-publish contract — adjacent to B058
(asynchrony) but distinct: B058 is *when* the menu reflects state;
B059 is *what* the reflected state contains.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: A
**Agent type:** team-reviewer
**Flake check:** N/A (static assertion review; no rerun needed)
**Reasoning:** PDF addBookmark at `src/renderer/src/components/pdf/components/pdf.tsx:345` hardcodes `label: \`Page ${pageNum}\``, so the production contract for this fixture is `/^Page \d+$/`. The spec at `e2e/menu-bookmarks-submenu.spec.ts:67-69` only checks the label is not one of three static strings and doesn't start with `(`, which would pass for `"undefined"`, `"NaN"`, `"null"`, `"[object Object]"`, or `bookmark.id`. `menuBuilder.ts:187-190` blindly forwards `b.label` from `bookmarks:list`, so a regression in the PDF formatter (or any future format) flows straight to the menu untested. Undercoverage is real; not a flake, not a bug, but a test-quality A-level gap.
**Suggested fix scope:** Tighten the assertion to `expect(labels.some((l) => /^Page \d+$/.test(l))).toBe(true)` (or compare against the `pageNumber` returned by the addBookmark IPC).
