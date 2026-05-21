---
id: B073
spec: e2e/menu-library.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-library.spec.ts` line 14 asserts the Window > Library accelerator
matches `/Cmd|Ctrl/`. This regex matches *any* string containing
either substring — `'Cmd+Backspace'`, `'Ctrl+Shift+W'`, even
`'CmdRandomCtrlString'`. The intent (per plan §2.2 bullet 4) is to
verify the accelerator is the canonical Library shortcut
(`'CmdOrCtrl+L'`). A regression that changed the accelerator to a
wrong-but-modifier-containing string would pass this test. Expected:
`expect(...accelerator).toBe('CmdOrCtrl+L')` (or whatever the canonical
binding is); actual: a near-tautological regex assertion.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-library.spec.ts` line `14`
- Failing assertion (current): `expect(findMenuItem(menu, ['Window', 'Library'])?.accelerator).toMatch(/Cmd|Ctrl/)`
- Missing assertion: exact-string check against the canonical
  accelerator constant
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/menu-library.spec.ts
  ```

## Tester Analysis
Accelerators are user-facing contracts — documentation, marketing
materials, and user muscle memory all encode the specific keystroke.
The regex as written verifies only that *some* modifier is present,
not that the correct combination is bound. This is a contract-shape
test (asserting what the menu builder advertises to Electron), not a
behavioral test, so there is no reason to be lenient on the value.
Pin it to the literal expected accelerator. If the production code
varies per platform, branch on `process.platform` and assert each
case explicitly; do not paper over the variance with a permissive
regex. Plan (`plan-menu-B.md` §2.2 bullet 4) flags this as a Practice
violation.

## Reviewer-1 Verdict: CONFIRM | REJECT
<append after wave 3>

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red -> minimal change -> refactor>
**Status:** fixed
**Commit:** b7b4c72a8a3472b1c09753218b37aaea55f8ea82
**Notes:** Replaced `.toMatch(/Cmd|Ctrl/)` with `.toBe(ACCELERATORS.focusLibrary)` (canonical `CmdOrCtrl+1`) and imported the shared accelerator constants for symbolic linkage to the production source. No production mismatch surfaced.

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

## Reviewer-1 Verdict: BUG
**Agent type:** team-reviewer
**Flake check:** N/A (static assertion review, not flake-prone)
**Reasoning:** `e2e/menu-library.spec.ts:14` uses `.toMatch(/Cmd|Ctrl/)`, which matches any string containing those substrings (e.g. `'CmdOrCtrl+Backspace'`, `'Ctrl+Shift+W'`). The canonical binding is `ACCELERATORS.focusLibrary = 'CmdOrCtrl+1'` (`src/main/menu/accelerators.ts:4`, wired at `src/main/menu/menuBuilder.ts:112`), and unit test `menuBuilder.test.ts:37` already pins it exactly — the e2e contract assertion should too. A regression renaming the binding to anything modifier-prefixed would silently pass.
**Suggested fix scope:** Replace the regex with `expect(...accelerator).toBe('CmdOrCtrl+1')` (importing `ACCELERATORS` for symbolic linkage is preferable).
