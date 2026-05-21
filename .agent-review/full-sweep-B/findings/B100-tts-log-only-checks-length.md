---
id: B100
spec: e2e/read-aloud-from-selection.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
Both TTS-log assertions in `read-aloud-from-selection.spec.ts` only check
`log.length > 0` — they never assert the *contents* of the request (CFI,
text, voice). A regression where the player issues a TTS request but for
the *wrong* selection (e.g., the previous selection's CFI, the page's
first paragraph, or empty text) would still pass.

## Reproduction
- Test file: `apps/rishi-electron/e2e/read-aloud-from-selection.spec.ts`
  - L141-142 (first test):
    ```ts
    const log = await readTtsLog(bookPage)
    expect(log.length).toBeGreaterThan(0)
    ```
  - L268-269 (IPC test):
    ```ts
    const log = await readTtsLog(bookPage)
    expect(log.length).toBeGreaterThan(0)
    ```
- Failing assertion: none in current form. Mutation example: if
  `handleReadAloudFrom` ignored the selectionStore CFI and always requested
  audio for `currentParagraphs[0]`, the log would still have entries and
  both tests would pass.
- How to run: `pnpm test:e2e e2e/read-aloud-from-selection.spec.ts`.

## Tester Analysis
The whole point of read-aloud-from-selection is "play *this* selection."
The contract the test should pin is "the TTS service receives a request
whose CFI matches the stored selection's CFI" (test 1) or "whose CFI
matches the live iframe selection's CFI" (test 3). Length-only assertions
test "*something* happened", which is a degenerate post-condition for a
feature whose entire value proposition is targeting.

The plumbing already exists. `readTtsLog` returns the same array shape
used in `tts-page-navigation.spec.ts` (which asserts on `r.cfiRange`,
`r.priority` at e.g. L700, L750-752, L938). Strengthen the assertions in
`read-aloud-from-selection.spec.ts` to match that pattern:

```ts
// Test 1 (L141): selection CFI was stored as `firstParagraphCfi`
const log = await readTtsLog(bookPage)
expect(log.some((r) => r.cfiRange === firstParagraphCfi)).toBe(true)
```

And for test 3 (L268), capture the iframe selection's resolved CFI (the
production resolver computes it from `window.getSelection()`) and assert
the first priority-1 request matches.

Secondary observation: if `readTtsLog` does not expose `cfiRange` /
`priority` for *every* request (only the high-priority ones), extend the
helper. Either way, `expect(log.length).toBeGreaterThan(0)` is below the
floor for a regression test on this feature.

## Reviewer-1 Verdict: CONFIRM (Class B)
**Agent type:** general-purpose
**Flake check:** N/A (static code review of assertion strength; no test execution required)
**Reasoning:** Confirmed at spec L141-142 and L268-269 — both assertions are `expect(log.length).toBeGreaterThan(0)`. The `readTtsLog` helper (player-helpers.ts L165-171) returns `{ cfiRange, text, priority }` for every entry, and `tts-page-navigation.spec.ts` L700, L748-751, L938-948 demonstrates the established pattern of asserting `r.cfiRange === expectedCfi` and `r.priority === 1`. Test 1 already captures `firstParagraphCfi` (L87-94) and pre-populates the selectionStore with it (L102-114), so a content-level assertion is trivially available without new plumbing. The feature's contract — "play *this* selection" — is not pinned: a mutation that requested audio for `currentParagraphs[0]` regardless of selection (or for stale CFI) would still pass. Class B (not BUG) because the production code may still be correct; this is a weak regression net, not a live defect.

**Suggested fix scope:** Replace both length-only asserts with `expect(log.some((r) => r.cfiRange === firstParagraphCfi)).toBe(true)` (test 1) and capture/assert the live iframe CFI for test 3.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
status: fixed
commit: <pending>
notes: Test 1 (stored selection) now asserts
`log.some((r) => r.cfiRange === firstParagraphCfi)` — the same CFI we
pre-populated into the selectionStore. Test 3 (live iframe selection)
captures the resolver-published CFI from the selectionStore *after* the
event dispatches (proving the live-selection path wrote it), then asserts
the TTS log contains that CFI. Both assertions now fail under the
"requests audio for currentParagraphs[0] regardless of selection" mutation
the finding called out. No helper changes needed; `readTtsLog` already
returns `{ cfiRange, text, priority }`. Typecheck green.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
