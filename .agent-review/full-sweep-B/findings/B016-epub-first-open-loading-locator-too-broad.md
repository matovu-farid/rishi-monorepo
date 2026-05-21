---
id: B016
spec: e2e/epub-first-open.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
The "first open of an EPUB renders content" spec asserts the absence of the
inner spinner with `bookPage.locator('text=Loading...').toHaveCount(0, ...)`.
This locator matches ANY DOM text node whose content equals "Loading..." —
including loaders rendered by the off-screen hidden paragraph reader that
mounts its own ReactReader without the cache (the same hidden surface called
out in `epub-cache-no-flash.spec.ts` L62–66). The companion cache-no-flash
spec deliberately filters to **visible** loaders precisely because the hidden
paragraph reader's loader is real DOM. As written, this spec can flip from
PASS to FAIL when the hidden reader's lifecycle changes — without any
user-visible regression — and conversely can PASS while the visible loader
is still up if the visible loader's DOM uses a different node shape (e.g.
`<span>` instead of `<p>`, or extra whitespace).

## Reproduction
- Test file: `apps/rishi-electron/e2e/epub-first-open.spec.ts` lines `L41-L44`
- Failing assertion (expected to be load-bearing on visible-loader only):
  ```
  await expect(
    bookPage.locator('text=Loading...'),
    'inner Loading… indicator clears once content is mounted'
  ).toHaveCount(0, { timeout: 5000 })
  ```
- How to run: `pnpm test:e2e e2e/epub-first-open.spec.ts`

## Tester Analysis
The bug being regressed-against (ArrayBuffer vs Uint8Array instanceof check
in the inner viewer's `initialize()`, comment at L11–23) manifests as a
**visible** infinite spinner. The current assertion is both too broad (catches
unrelated hidden loaders) and too narrow (relies on exact text-node match).
The asymmetry with `epub-cache-no-flash.spec.ts` — which goes to substantial
lengths to filter for `visibleToUser(...)` at L74–94 — proves the project
already knows the broad locator is wrong here.

Production code paths to verify:
- `src/renderer/src/modules/reader/EpubReader/...` (visible reader path)
- The hidden paragraph-reader path (search for the "off-screen with opacity:0"
  comment in the cache-no-flash design block, L62–66).

Recommended fix in the test: scope the locator to a visibility-checked
predicate (mirroring cache-no-flash) OR pin to the specific visible loader
container (e.g. `[data-testid="epub-loading"]` if added).

## Reviewer-1 Verdict: B
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** N/A (classification B — test design defect, not a code BUG; no live re-runs needed)
**Reasoning:** Confirmed both reader mounts in `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx` render the SAME `loadingView={<Loader />}` — main visible reader at L984-988 and hidden paragraph reader at L1163-1184 (wrapped in `opacity-0` parent). `Loader` (`src/renderer/src/components/Loader.tsx` L7) emits `<p>Loading...</p>`. Playwright's `text=Loading...` matches text-content regardless of visibility, so it catches the hidden reader's `<p>` while the off-screen ReactReader is still initializing. The companion `e2e/epub-cache-no-flash.spec.ts` L74-94 explicitly implements `visibleToUser(...)` precisely because the hidden paragraph reader's loader is real DOM (see comment L61-66). The first-open spec at L41-44 lacks this visibility filter, making the assertion both over-broad (catches hidden loader) and brittle to DOM-shape changes. The regression-under-test (instanceof ArrayBuffer in inner `initialize()`) produces a *visible* infinite spinner, so a visibility-scoped assertion is what's actually load-bearing.
**Suggested fix scope:** Replace L41-44 assertion with a visibility-scoped predicate mirroring `epub-cache-no-flash.spec.ts` L74-94, or add a `data-testid="epub-loading"` on the visible loader container in `EpubView.tsx` L984 and target that.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
