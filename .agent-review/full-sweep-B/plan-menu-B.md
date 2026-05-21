# Plan — Menu Specs (Phase B / P6)

Scope (3 specs, all under `apps/rishi-electron/e2e/`):

- `menu-commands.spec.ts` — native menu → renderer command dispatch (View > Dark Mode, Bookmarks > Add Bookmark).
- `menu-library.spec.ts` — library-window menu structure (top-level labels + accelerators).
- `menu-recent.spec.ts` — File > Open Recent population + click → opens window.

All three drive the real Electron app via `e2e/helpers/electron-app.ts`
(`launchApp` / `closeApp` / `clickMenuItem` / `getApplicationMenu` /
`findMenuItem` / `importBook` / `openBook`). They depend on the same
focus-shaping pattern (focus the right BrowserWindow before sending a
synthetic menu click) because macOS rebuilds the app menu per focused
window.

---

## 1. Skip list

The following are explicitly OUT of scope for this planner's audit
(testers MUST NOT file findings against them):

- The `e2e/helpers/electron-app.ts` helper itself (`clickMenuItem`,
  `getApplicationMenu`, `findMenuItem`, `importBook`, `openBook`). Bugs
  in the helper surface as bugs in *every* spec; that is a separate
  cross-cutting audit, not part of this slice.
- The production menu builder (`src/main/menu.ts` or equivalent) and the
  renderer-side menu IPC bridge — production targets, NOT test files.
  Findings about production code go through the normal finding flow but
  are not part of *this* plan's "audit the tests" mandate.
- Bookmarks DB schema and migrations — `menu-commands.spec.ts` reads
  `bookmarksList(syncId)`; the schema is out of scope.
- TTS/Voice-chat menu items (not exercised by these three specs).
- Any `test.skip(...)` block — note as a parity gap (`parity-gaps.md`),
  do not file as a finding.
- Per-platform shortcut wording differences (Cmd vs Ctrl) beyond the
  regex `menu-library.spec.ts` already uses.

---

## 2. Per-file audit checklist

Reuse the P5 anti-pattern list (timing-based `waitForTimeout` in
assertions, tautological assertions, weak `body.not.toBeEmpty()`-style
assertions, implementation-detail selectors, asymmetric ErrorBoundary
coverage, `setTimeout`-as-assertion, missing reset/cleanup). PLUS the
P6-specific anti-patterns below.

### 2.1 `menu-commands.spec.ts`

- **L17-24, L31, L78, L113, L118** — Multiple `waitForTimeout(200/300/
  400/1200/1800)` calls. Some are setup pacing (acceptable but flaky);
  L31 and L118 are *between* an action and the assertion that follows
  — those should use `expect.poll(...)` against
  `document.documentElement.classList` / `bookmarksList(sid).length`
  instead. **Practice violation candidate** if any appear inside the
  assertion window.
- **L42** — `test.setTimeout(120000)` is two minutes; if the bookmark
  add IPC is slow, this masks it. Same pattern flagged in
  `azw3-real-import-routing.spec.ts:23` in P5.
- **L65-68** — `test.skip(true, ...)` triggers a *conditional* skip
  when `bookSyncId` cannot be assigned. This silently hides
  `saveBook` regressions in the seeding path; consider whether a
  failed seed should `expect(syncId).not.toBeNull()` instead.
  **Practice violation** — conditional skips hide bugs.
- **L94-127** — Five-retry loop around the menu click. The retry is
  rationalized by focus-bouncing on macOS, but the loop pattern means
  a real "Add Bookmark dispatches twice" bug would be invisible (the
  count just goes up; we never check it went up by exactly 1). Add a
  bound: `expect(after - before).toBe(1)` or `.toBeLessThanOrEqual(5)`.
  **Possible bug-masking** — record as practice violation.
- **menu-vs-keyboard parity** — both items tested here (View > Dark
  Mode toggle, Bookmarks > Add Bookmark) also have keyboard shortcuts
  registered in the menu definition. No keyboard-driven counterpart
  test exists. **Parity gap** — accelerator path is not exercised.
- **L11-39** — Dark-mode toggle: asserts the class flipped, but does
  NOT assert it persisted (closing/relaunching the app would re-run
  this toggle from default). **Parity gap** vs. theme persistence.
- **Cleanup**: `closeApp(launched)` is in `finally` (good). Does
  `closeApp` purge the userDataDir / DB so the bookmark added here
  cannot leak into another test? Confirm against helper; if not,
  **practice violation** (test pollution).

### 2.2 `menu-library.spec.ts`

- **L8** — Asserts `expect.arrayContaining([...])` on top-level labels.
  Order is not checked. The menu builder probably has a fixed order
  (File first, Help last); a regression that reorders Window before
  View would slip past. **Practice violation** (loose assertion) —
  consider `expect(labels).toEqual(['File', 'Edit', 'View', 'Window',
  'Help'])`.
- **L10-11** — Asserts Bookmarks/Reader are absent from the *library*
  menu. Good behavior-over-implementation assertion (these belong to
  reader windows only). Defend this pattern.
- **L13** — `findMenuItem(menu, ['File', 'Import Book…'])` uses a
  literal ellipsis (`…`, U+2026). If a future commit normalizes
  labels to `...` (three dots), this silently breaks. **Practice
  observation** — pin the canonical label in a constant, or assert
  via regex `/^Import Book/`.
- **L14** — Accelerator regex `/Cmd|Ctrl/` accepts any string
  containing those tokens — `'CmdOrCtrl+L'` matches, but so does
  `'Cmd+Backspace'`. Tighten to assert the specific accelerator
  (`'CmdOrCtrl+L'` or similar). **Practice violation**.
- **menu-vs-keyboard parity** — accelerator presence is asserted but
  not exercised. A separate test should press the accelerator and
  verify the library window appears. **Parity gap**.
- **library state mutations** — this spec doesn't import any books, so
  cleanup is moot. If it later seeds the library, ensure
  `closeApp(launched)` is in `finally` and the userDataDir is torn
  down. Currently OK.
- **No assertion that reader windows DO have Bookmarks/Reader menus.**
  This spec covers the library-only side; a parity counterpart
  (`menu-reader.spec.ts` or similar) is needed. **Parity gap**.

### 2.3 `menu-recent.spec.ts`

- **L24, L32, L42, L50** — Four `waitForTimeout(200/500/400/1800)`.
  L42 is between `refreshMenu()` and reading the rebuilt menu; should
  be `expect.poll(...)` against `findMenuItem(menu, ['File', 'Open
  Recent'])?.submenu?.length`. L50 (after click) should poll
  `launched.app.windows().length`. **Practice violation**.
- **recent-files ordering (FIFO/LRU)** — only one book is imported,
  so order isn't testable here. The spec does not assert the LRU
  position of "Recent A" — if recents come back in arbitrary order,
  a single-element list still passes. **Parity gap**: import N≥3
  books and assert the most-recent appears first; verify reopening
  one re-promotes it.
- **No cap test** — recent files lists typically cap at 5-10
  entries; no test imports >cap and asserts the oldest falls off.
  **Parity gap**.
- **No persistence test** — closes the app at end of test; never
  reopens to assert Open Recent survives a restart. **Parity gap**.
- **L46** — `recent?.submenu?.some((m) => m.label === 'Recent A')`
  uses `.some(...)`. If the same book appears twice (a dedup bug),
  this still passes. Consider `.filter(...).length === 1`.
  **Practice violation**.
- **L49** — `clickMenuItem(launched.app, ['File', 'Open Recent',
  'Recent A'])` returns true even if the click was delivered but the
  handler swallowed the open call. The subsequent
  `launched.app.windows().length > before` is the real assertion —
  good — but it doesn't verify the *correct* book opened. Add an
  assertion against the new window's URL containing the imported
  book's id. **Practice violation** (weak assertion).
- **menu-vs-keyboard parity** — Open Recent typically has no
  accelerator (submenu); not applicable. No parity gap.
- **library state mutations** — `importBook` writes to the DB inside
  the per-test userDataDir; `closeApp(launched)` should tear it down.
  Confirm against helper. If userDataDir is reused across runs, the
  imported "Recent A" pollutes future runs. **Practice observation**.

---

## 3. Tester ID range

**B071-B085** assigned to **Tester B-T6** (this slice's tester pool).

- Soft cap 5 findings/spec → max 15 findings across the 3 specs.
- Tester B-T6 reserves IDs B071-B085 for findings filed against this
  slice.
- Reviewer-1 alternation (per pilot plan §4.4):
  - IDs ending odd digit (B071, B073, ...) → `team-reviewer`.
  - IDs ending even digit (B072, B074, ...) → `feature-dev:code-reviewer`.
- Parity gaps go to `.agent-review/full-sweep-B/parity-gaps.md`
  (NOT to `findings/`); practice violations go to
  `.agent-review/full-sweep-B/practices-audit.md`.

---

## 4. Test commands

### 4.1 Build prerequisite

All three are Playwright e2e specs; they require a built main process
at `apps/rishi-electron/out/main/index.js`. Build first:

```bash
pnpm --filter rishi-electron build
```

(No `pretest:e2e` hook — manual.)

### 4.2 Run a single spec

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/menu-commands.spec.ts
pnpm test:e2e e2e/menu-library.spec.ts
pnpm test:e2e e2e/menu-recent.spec.ts
```

### 4.3 Run a single test by name

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/menu-commands.spec.ts -g "Add Bookmark"
```

### 4.4 Reviewer-1 flake check (≥3 runs)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/menu-commands.spec.ts -g "<name>" \
  || echo "run $i: FAIL"; done
```

### 4.5 Dry-run discovery (before citing in a finding)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/menu-commands.spec.ts
```
