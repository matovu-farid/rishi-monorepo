---
id: B019
spec: e2e/epub-text-selection.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The "mousedown on the reader area is not preventDefault-ed" test
(L126–152) selects its synthetic-event target via
`iframe.parentElement?.parentElement ?? iframe.parentElement ?? iframe`
(L139). This anchors the assertion to the iframe's grandparent — an
unnamed wrapper whose identity depends entirely on ReactReader's internal
DOM nesting. Any refactor that adds or removes one wrapper div between
the iframe and the scroll/swipe container will silently change which
element receives the synthetic `mousedown`, potentially dispatching the
event into a child of (or outside of) the SwipeWrapper region. The test
would either silently pass on a regression (if the new target sits below
the SwipeWrapper in the tree, so an active SwipeWrapper above it does
not see the event) or silently fail on a benign DOM cleanup. Neither is
the intended user-observable contract: "text in the iframe is
selectable."

## Reproduction
- Test file: `apps/rishi-electron/e2e/epub-text-selection.spec.ts` lines `L126-L152`
- Fragile target selection (L139):
  ```
  const target = iframe.parentElement?.parentElement ?? iframe.parentElement ?? iframe
  ```
- How to run: `pnpm test:e2e e2e/epub-text-selection.spec.ts -g "mousedown"`

## Tester Analysis
The companion test at L87–124 already asserts the overlay's structural
absence robustly (computed-style match on a documented signature). The
synthetic-mousedown test exists to catch the case where the overlay is
present but mousedown is somehow not prevented — a strictly weaker
regression mode. The fragile target choice undermines that intent: the
test does not target the SwipeWrapper itself, only a guessed ancestor of
the iframe. If the goal is "the SwipeWrapper does not preventDefault on
mousedown," the test should:
1. Query the SwipeWrapper directly (e.g. by its computed-style signature
   from the L87 test), or
2. Be deleted in favor of an actual selection-behavior test (open the
   iframe document, perform a real range selection on a known text node,
   assert `iframe.contentWindow.getSelection().toString()` is non-empty).

Option 2 is preferable: it tests the user-observable contract directly
and survives any DOM refactor. The current target-walking dance is impl-
detail-coupled in a way the rationale block at L1–42 explicitly warns
against for the structural test.

## Reviewer-1 Verdict: CONFIRM
**Agent type:** team-reviewer
**Flake check:** N/A (static review of test target-selection logic; no run needed)
**Reasoning:** L139 walks `iframe.parentElement?.parentElement` — an unnamed wrapper whose identity depends on ReactReader internals; this is the very impl-detail coupling the L1–42 rationale block warns against. The L87 structural test already proves overlay absence via computed-style signature, so the mousedown test as written either passes vacuously when no overlay exists, or could miss a regression if a wrapper div is added/removed (dispatch target ends up below the SwipeWrapper, so an active SwipeWrapper above it never receives the synthetic event and `defaultPrevented` stays false). Should target the SwipeWrapper directly by its computed-style signature, or assert a real `iframe.contentWindow.getSelection().toString()` is non-empty.
**Suggested fix scope:** Replace the parentElement walk with either a computed-style query for the swipeWrapper ancestor or a real iframe-document selection assertion.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** 8f5429360657b9008b6c2bf1b607ae4e62dcaa3a
**Notes:** Replaced the synthetic-mousedown / `parentElement?.parentElement` walk with the reviewer's preferred Option 2: drive a real `Range` selection inside the epub.js iframe's own document on the first non-empty text node, then assert `getSelection().toString()` is non-empty. Scans all iframes (epub.js mounts more than one) and polls briefly for rendered text. No longer couples to ReactReader's wrapper-div nesting; tests the user-observable contract directly.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
