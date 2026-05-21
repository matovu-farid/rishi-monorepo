# Practices Audit — Tester B-T6 (Menu specs, P6)

Scope: `apps/rishi-electron/e2e/menu-commands.spec.ts`,
`menu-library.spec.ts`, `menu-recent.spec.ts`. Practice observations
that did not rise to filed findings (or that complement findings
B071-B075) live here. Findings themselves are cross-referenced.

## Filed as findings

- **B071** — `menu-commands.spec.ts` L94-128 retry loop uses
  exit-on-change and asserts `>`, masking duplicate-dispatch bugs.
- **B072** — `menu-library.spec.ts` L9 `expect.arrayContaining`
  asserts membership, not order.
- **B073** — `menu-library.spec.ts` L14 `/Cmd|Ctrl/` regex is too
  permissive for an accelerator-contract assertion.
- **B074** — `menu-recent.spec.ts` L46 `.some(...)` cannot detect a
  dedup-failure regression that surfaces as duplicate entries.
- **B075** — `menu-recent.spec.ts` L49-51 asserts a new window opened
  but not that it opened the *correct* book.

## Recorded here only (not findings, soft cap = 5)

### P1. `waitForTimeout` inside assertion windows
- `menu-commands.spec.ts` L31 (between menu click and theme-after
  read), L113-118 (between focus, click, and count read inside the
  retry loop)
- `menu-recent.spec.ts` L42 (between `refreshMenu()` and
  `getApplicationMenu`), L50 (between menu click and window-count
  assertion)
- Pattern: an `await waitForTimeout(N)` immediately preceding an
  `expect(...)` is a flake amplifier and a race-condition oracle.
  Replace with `expect.poll(...)` against the same value. The
  pre-action `waitForTimeout(200)` calls in `menu-commands.spec.ts`
  L24 and `menu-recent.spec.ts` L24 are pacing-after-focus and
  acceptable.

### P2. Two-minute per-test timeout
- `menu-commands.spec.ts` L42 — `test.setTimeout(120000)` for "Add
  Bookmark". A 2-minute budget on a single bookmark-add test masks
  IPC slowness regressions; if the action ever crosses 5-10s under
  load the test still passes (just slowly). Same shape was flagged
  in P5 against `azw3-real-import-routing.spec.ts:23`. Consider
  trimming once the retry loop in B071 is replaced with
  `expect.poll`.

### P3. Literal Unicode ellipsis in label match
- `menu-library.spec.ts` L13 — `findMenuItem(menu, ['File', 'Import
  Book…'])` uses U+2026. A label-normalization commit that switches
  to three ASCII dots `...` (or vice-versa) silently breaks this
  test. Pin the canonical form in a shared constant or use a regex
  like `/^Import Book/`.

### P4. `bringToFront` + focus race in retry loop
- `menu-commands.spec.ts` L97-111 — retry loop interleaves
  `BrowserWindow.focus()` (main-process) with `page.bringToFront()`
  (CDP). On macOS these can fight each other for focus when the
  parent library window is also visible. Document the precedence or
  unify on one mechanism inside the helper (helper change is out of
  scope per plan §1, but worth recording for the helper audit).

### P5. `crypto.randomUUID()` inside the page evaluate
- `menu-commands.spec.ts` L61 — seeding a syncId in-renderer via
  `crypto.randomUUID()` works but couples the test to whichever
  syncId format production happens to accept today. If production
  later validates syncIds against a stricter shape (e.g. tagged
  prefix), this seed will start producing rows that the production
  bookmark code rejects, and the test will start flaking. Prefer
  invoking the production helper that mints syncIds, or seed via the
  same IPC the background sync uses.

## What was checked and is fine

- All three specs wrap `closeApp(launched)` in `finally` — good
  cleanup discipline.
- `menu-library.spec.ts` L10-11 negative assertions (`not.toContain`
  for Bookmarks / Reader on the library window) are a textbook
  behavior-over-implementation contract; do not weaken.
- `menu-recent.spec.ts` L31 `expect(a.id).toBeGreaterThan(0)` after
  `importBook` is a useful sanity check on the seed step.
- ESLint disable comments on the retry loop (`no-await-in-loop`) are
  individually justified with comments — the rule disable itself is
  appropriate for sequential E2E retry; the broader concern about
  the loop is B071.
