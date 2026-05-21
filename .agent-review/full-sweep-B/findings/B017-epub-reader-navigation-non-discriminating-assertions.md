---
id: B017
spec: e2e/epub-reader.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
Three navigation tests in `epub-reader.spec.ts` — `next-page click does not
crash` (L44), `keyboard arrows navigate without crashing` (L59), and
`rapid forward navigation does not crash` (L68) — finish by asserting
something that is true regardless of whether navigation actually occurred:
`[aria-label="Next page"]` is still visible (L47, L65) or `body` is visible
(L75). Clicking the Next button does not unmount it; the body is always
visible. These tests would all pass even if the click handler were a no-op,
or if the `book.rendition.next()` call silently swallowed an error and left
the iframe on page 1. There is no assertion that the location/CFI actually
changed.

## Reproduction
- Test file: `apps/rishi-electron/e2e/epub-reader.spec.ts` lines `L44-L76`
- Failing assertions (current; non-discriminating):
  - L47: `await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()`
  - L65: same shape, after ArrowLeft/ArrowRight
  - L75: `await expect(bookPage.locator('body')).toBeVisible()`
- How to run: `pnpm test:e2e e2e/epub-reader.spec.ts`

## Tester Analysis
The user-observable behavior is page progression, not button visibility. A
stronger assertion is a CFI / location signal change. Production code surface:
the EpubReader stores location in window state (see
`src/renderer/src/modules/reader/EpubReader/` and the existing
`__readerCache.epub` window surface). A minimal contract assertion:
- Read location/CFI before click via a window-evaluated getter.
- Click Next.
- Poll (`expect.poll`) the same getter for a value change within e.g. 3s.

Without this, a real regression — e.g. the renderer's `next()` handler
throws and gets swallowed by an error boundary that leaves the toolbar
intact — would pass all three tests. The plan document already flagged
this exact pattern in §2.3 L44–48, L68–76.

Note: this is a **test-quality** finding (the test cannot fail when the
behavior it claims to verify breaks). It is filed as a finding rather than
a practices-audit note because it materially undermines what readers of CI
green believe about the EPUB navigation path.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** f9e25b324a835d3e7f0ce1a2fea04c92ced958f4
**Notes:** Replaced body/button-visibility assertions in `next-page click`, `keyboard arrows`, and `rapid forward navigation` tests with `expect.poll` over `getBookLocation` (IPC-backed persisted CFI). EPUB writes location to the DB via `updateBookLocation` on every `relocated` event, so the persisted value is the discriminating signal — a swallowed-error or unbound handler leaves it stale and now fails the test. The trailing button-visibility check remains as a cheap shell-still-up sanity check. Test names renamed from "does not crash" to "advances/changes the persisted CFI" to reflect the actual contract.
**E2E mutation check:** env-blocked (pre-existing `launchApp`/`closeApp` teardown timeout in sandbox); typecheck passes.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: BUG
**Agent type:** team-reviewer
**Flake check:** N/A (test-quality finding; no execution needed)
**Reasoning:** L47/L65 reassert the same locator the `beforeEach` already waited on (L34) — Next button visibility is stable across click; L75's `body` visibility is trivially true. No CFI/location read or change-detection. A no-op or swallowed-error click handler passes all three tests, defeating the stated intent ("does not crash" via missing state-change signal).
**Suggested fix scope:** Add an `expect.poll` over a window-evaluated CFI/location getter (e.g. `__readerCache.epub.location`) before/after each navigation to assert page actually advanced.
