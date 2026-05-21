---
id: B031
spec: e2e/pdf-import.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The test named `"PDF imports, opens, and renders pages"` (pdf-import.spec.ts L38-56) never asserts that any PDF page is rendered. The only post-open assertion is `expect(bookPage.locator('div.overflow-y-scroll').first()).toBeAttached({ timeout: 15000 })` (L52) — i.e. the reader's scroll container is *attached* (not even visible) — followed by an unconditional `bookPage.waitForTimeout(3000)`. A regression in which the reader shell mounts but `react-pdf` fails to render any `canvas.react-pdf__Page__canvas` (PDF.js worker failure, font-loader error, blank-canvas race) would not fail this test. The test name promises "renders pages"; the assertion delivers "scroll container exists in the DOM".

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-import.spec.ts` lines `38-56`
- Failing assertion (current, too-weak): `await expect(bookPage.locator('div.overflow-y-scroll').first()).toBeAttached({ timeout: 15000 })`
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm test:e2e e2e/pdf-import.spec.ts -g "PDF imports, opens, and renders pages"
  ```

## Tester Analysis
The production code path under test is the PDF reader render pipeline (renderer mounts `PdfReader`, react-pdf loads the document via `pdfjs-dist` worker, individual `<Page>` components emit `<canvas class="react-pdf__Page__canvas">`). User-visible promise: "I opened a PDF; I see a page." `toBeAttached` on the scroll-shell does not exercise that pipeline at all — the shell mounts before any document load and is attached even when the worker throws or returns zero pages.

Asymmetry vs. EPUB sibling (same file, L58-68): the EPUB test asserts `bookPage.locator('[aria-label="Next page"]').first()` is visible — a true reader-content assertion. PDF gets only the shell.

This crosses the "finding vs practice" line because:
1. A real production regression (blank-canvas) would slip past this test.
2. The fix is a one-line locator swap to `canvas.react-pdf__Page__canvas` with `toBeVisible` (or a `data-testid` once added). No infrastructure change required.
3. The asymmetry with EPUB shows the team already knows how to write this assertion.

Not a parity gap (those are about real-import dispatcher coverage); this is a missing assertion that masks a renderable-region regression.

## Reviewer-1 Verdict: BUG
**Agent type:** team-reviewer
**Flake check:** N/A (assertion-strength finding, not flaky)
**Reasoning:** pdf-import.spec.ts L52 only asserts `div.overflow-y-scroll` is `toBeAttached` — the shell mounts in `pdf.tsx` independent of `react-pdf` page render. No locator targets `canvas.react-pdf__Page__canvas` (the actual rendered surface produced by `Page` in `components/pdf/components/pdf-page.tsx:10`). EPUB sibling at L65 correctly asserts a content locator (`[aria-label="Next page"]` visible). A blank-canvas/worker-failure regression in the react-pdf pipeline would pass this test, contradicting the test name "renders pages".
**Suggested fix scope:** Replace L52-55 with `await expect(bookPage.locator('canvas.react-pdf__Page__canvas').first()).toBeVisible({ timeout: 15000 })` and drop the unconditional 3s sleep.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** c2bc333d4eb1f8d4438760c93bc9bb6333b808b5
**Notes:** Replaced the L52-55 `toBeAttached(div.overflow-y-scroll)` + 3s `waitForTimeout` with `toBeVisible(canvas.react-pdf__Page__canvas)` at the same 15s timeout. The canvas is the actual rendered surface emitted by `Page` in `components/pdf/components/pdf-page.tsx`, so a blank-canvas / pdfjs worker failure now fails the test instead of slipping past on shell-mount alone. Brings PDF in line with the EPUB sibling at L65 (`Next page` aria-label visible).
**E2E mutation check:** env-blocked (sandbox teardown timeout); typecheck passes.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
