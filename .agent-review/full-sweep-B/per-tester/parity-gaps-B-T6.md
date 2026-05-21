# Parity Gaps — Tester B-T6 (Menu specs, P6)

Scope: `apps/rishi-electron/e2e/menu-commands.spec.ts`,
`menu-library.spec.ts`, `menu-recent.spec.ts`. Gaps below are not
filed as findings (per plan §1: "Any `test.skip(...)` block — note as
a parity gap, do not file as a finding"; per `plan-menu-B.md` §2 the
parity-counterpart gaps also belong here, not in `findings/`).

## menu-commands.spec.ts

### 1. menu-vs-keyboard parity — Dark Mode toggle
- Spec: `e2e/menu-commands.spec.ts` L11-39
- Gap: Test exercises View > Switch to Dark/Light Mode via menu click
  only. The same item has a keyboard accelerator registered in the
  menu builder; the accelerator path is never pressed.
- Counterpart needed: send the accelerator (Playwright
  `page.keyboard.press('Meta+Shift+D')` or whatever is bound) and
  assert the same class flip on `document.documentElement`.

### 2. menu-vs-keyboard parity — Add Bookmark
- Spec: `e2e/menu-commands.spec.ts` L41-132
- Gap: Same as above for Bookmarks > Add Bookmark — accelerator path
  is unexercised; only the menu-click path is tested.

### 3. theme persistence parity
- Spec: `e2e/menu-commands.spec.ts` L11-39
- Gap: Dark-mode toggle asserts the class flipped but never closes
  and relaunches the app to verify the preference persisted. A
  preferences-store regression that resets to light on launch would
  not be caught.

### 4. conditional test.skip hides syncId regressions
- Spec: `e2e/menu-commands.spec.ts` L65-68
- Gap: `test.skip(true, 'bookSyncId could not be assigned for the
  imported PDF')` silently skips when the seed step's `saveBook`
  returns no syncId. Per plan §1 ("Any test.skip(...) block — note as
  a parity gap"), recorded here. Counterpart needed: replace the
  conditional skip with `expect(syncId).not.toBeNull()` so a broken
  seed path fails loud.

## menu-library.spec.ts

### 5. reader-window menu counterpart
- Spec: `e2e/menu-library.spec.ts` L4-18
- Gap: This spec verifies the *library*-window menu lacks Bookmarks/
  Reader. There is no symmetric spec verifying the *reader*-window
  menu *contains* Bookmarks and Reader. A menu-builder regression
  that stripped those from reader windows would slip past.
- Counterpart needed: a `menu-reader.spec.ts` (or extension here)
  that opens a book, focuses the reader window, calls
  `getApplicationMenu`, asserts `['Bookmarks', 'Reader']` are
  present, and asserts their key items (Add Bookmark, etc.) exist.

### 6. menu-vs-keyboard parity — Window > Library
- Spec: `e2e/menu-library.spec.ts` L14
- Gap: Accelerator presence is asserted via regex but never pressed.
  Counterpart needed: focus a non-library window, press the
  Window > Library accelerator, assert the library window comes to
  front.

## menu-recent.spec.ts

### 7. recent-files LRU ordering
- Spec: `e2e/menu-recent.spec.ts` L12-55
- Gap: Only one book ("Recent A") is imported, so order is
  untestable. Most-recent-first ordering is core to the Open Recent
  UX; a recents-manager regression that returns them in arbitrary or
  insertion order is invisible to this single-element test.
- Counterpart needed: import ≥3 books, assert the most-recently
  opened sits at the top of the submenu, then re-open an older entry
  and assert it promotes to the top.

### 8. recent-files cap
- Spec: `e2e/menu-recent.spec.ts` L12-55
- Gap: Recent files lists typically cap at 5-10 entries; nothing
  here imports past the cap or asserts the oldest falls off.
- Counterpart needed: import (cap+1) books and assert the submenu
  contains exactly the cap and the first-imported book is gone.

### 9. recent-files persistence across restarts
- Spec: `e2e/menu-recent.spec.ts` L12-55
- Gap: Spec imports + verifies in a single launch. Open Recent is a
  persistent-store feature; restart parity is not verified.
- Counterpart needed: import, `closeApp`, `launchApp` again, then
  assert the submenu still contains the import.

## Cross-cutting

### 10. library-state cleanup confirmation (deferred to helper audit)
- Specs: all three
- Gap: The plan (§2.1, §2.3) asks whether `closeApp(launched)` purges
  userDataDir / DB. Per plan §1 the helper itself is out of scope for
  this slice — recorded here as a pending cross-cutting question for
  the helper audit, not as a finding against these three specs.
