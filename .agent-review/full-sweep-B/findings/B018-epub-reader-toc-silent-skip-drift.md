---
id: B018
spec: e2e/epub-reader.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
The TOC toggle test at L50–57 uses a conditional `test.skip(true, 'no TOC
toggle in this build')` when the selector `[aria-label="Toggle table of
contents"]` returns count 0. There is no positive precondition that the
selector exists in CI's known-good build. If the aria-label is ever renamed
(e.g. to "Toggle TOC" or localized), every CI run will silently skip this
test forever — green CI hides a real regression in TOC discoverability.
Combined with the spec's lack of any TOC fixture/build assertion elsewhere,
this is a one-way ratchet: the test can disappear from coverage with zero
signal.

## Reproduction
- Test file: `apps/rishi-electron/e2e/epub-reader.spec.ts` lines `L50-L57`
- Mechanism (L52): `if ((await tocToggle.count()) === 0) test.skip(true, 'no TOC toggle in this build')`
- How to run: `pnpm test:e2e e2e/epub-reader.spec.ts -g "TOC toggle"`

## Tester Analysis
Conditional skips are valid when the gated capability is genuinely optional
across configurations (e.g. mic permissions on macOS). The TOC toggle is
not optional — it ships in the default build. Recommended remediation
(test-side):
- Promote the precondition: instead of skip, fail with a clear message when
  the selector is missing in CI, e.g. assert `await expect(tocToggle).toBeVisible()`
  before any branching, OR
- Have a `beforeAll` smoke that probes for the TOC toggle aria-label and
  fails the whole describe block if absent — making the regression loud.

This is filed as a finding (rather than practices-audit) because the
silent-skip mechanism actively erases coverage; the plan flagged exactly
this risk in §2.3 L50–57 and Skip-List notes.

## Reviewer-1 Verdict: BUG-A
**Agent type:** general-purpose
**Flake check:** N/A (static selector audit)
**Reasoning:** `TocToggleButton.tsx:19` renders `title="Toggle Table of Contents"` with NO `aria-label` attribute (only NavigationArrows L38/L50 and the TOC panel itself L85 use aria-label). The spec's selector `[aria-label="Toggle table of contents"]` therefore returns count 0 in EVERY build — the conditional at `epub-reader.spec.ts:52` makes the test skip on every CI run, permanently. This is not a defensible conditional-skip pattern: the gated capability is not optional, and the precondition is never satisfied even in the default build. The tester's "silent erasure of coverage" framing is exactly right — the test has been dead since it was written.
**Suggested fix scope:** Replace selector with `[title="Toggle Table of Contents"]` (or add `aria-label` to `TocToggleButton`) AND remove the conditional skip in favor of `await expect(tocToggle).toBeVisible()`.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** abandoned
**Commit:** none
**Notes:** Attempted Option A (test-only): replaced `[aria-label="Toggle table of contents"]` with `getByTitle(/toggle table of contents/i)` and removed the conditional skip. The corrected test then ran against the production build and failed — `getByTitle(/toggle table of contents/i)` was not visible within 10s, meaning the TocToggleButton from `src/renderer/src/components/react-reader/components/TocToggleButton.tsx` is not actually rendered in the running EPUB reader (the silent-skip masked a real coverage gap: TOC toggle is missing from the shipped EPUB reader UI, not just mis-labeled). Per process step 5, spec change reverted; no commit. Follow-ups required before this finding can be closed: (1) feature/UI fix to ensure TocToggleButton is mounted in the EPUB reader path used by `openBook` in e2e, (2) once the button renders, apply Option A selector fix, (3) Option B (add `aria-label="Toggle table of contents"` to `TocToggleButton.tsx`) remains a worthwhile a11y enhancement and should be queued as a separate follow-up regardless.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
