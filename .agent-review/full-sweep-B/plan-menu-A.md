# Plan — Menu Specs Group A (P5)

**Scope (3 specs):**
- `apps/rishi-electron/e2e/menu-book-epub.spec.ts`
- `apps/rishi-electron/e2e/menu-book-pdf.spec.ts`
- `apps/rishi-electron/e2e/menu-bookmarks-submenu.spec.ts`

**Tester ID range:** B056-B070 (Tester B-T5). Cap 5 findings/spec; alternate
`reviewer1_agent_type` by trailing digit (odd → `team-reviewer`, even →
`feature-dev:code-reviewer`).

---

## 1. Skip list

No test in these three files is `test.skip(...)`. All three are single-test
specs and currently active. Do not, however, treat "active" as "asserting
behavior under realistic timing" — see §2 below. Parity gaps live in
*missing* tests (the symmetric format coverage between EPUB and PDF) rather
than in skipped ones.

Out of scope for this group:
- Production code edits (`src/main/menu/*`, `src/main/ipc/menu.ts`,
  Bookmarks-publish IPC). Findings cite production paths but do not modify.
- Application menu *contents* outside the items the three specs assert
  (File, Edit, Window are unrelated to the focused-book menu contract).
- The Library-window menu shape (no spec in this group covers it).

---

## 2. Per-file audit checklist

### 2.1 `e2e/menu-book-epub.spec.ts`

Focus: EPUB-focused book window should expose `Show TOC` under View, and
must NOT expose PDF-only items (`Show Thumbnails`, `Dual Page`).

- **L21, L41** — `bookPage.waitForTimeout(2500)` and `launched.page.waitForTimeout(800)`.
  Hard-coded waits in lieu of polling. The menu rebuild on focus is async
  (IPC round-trip → main rebuilds → re-applies). Prefer `expect.poll(...)`
  against `getApplicationMenu(...)` returning the expected shape. Record in
  `practices-audit.md` (timing-based assertion).
- **L27** — `launched.page.waitForTimeout(500)` "settle" before
  `electronApplication.evaluate`. The comment admits the evaluate races with
  navigation. This is a known foot-gun on `electronApplication.evaluate`;
  consider whether `bookPage.waitForLoadState('domcontentloaded')` would be
  more deterministic. **Practice violation** at minimum.
- **L40** — `.catch(() => {})` swallows evaluate failures silently. If the
  focus call throws, the menu assertion that follows is measuring the
  *previous* menu, not the focused-book menu. **Practice violation** —
  errors should at least be logged and the test should fail loudly if focus
  cannot be acquired.
- **L44-46** — Asserts `Show TOC` defined AND `Show Thumbnails` /
  `Dual Page` undefined. Good behavioral contract. Verify against the menu
  builder (`src/main/menu/*`): is "Show TOC" guaranteed for EPUB? If the
  builder gates on a runtime capability flag, the assertion could be flaky
  across formats. Potential **bug** if EPUB doesn't always carry TOC.
- **L48** — Asserts top-level menu *contains* `Bookmarks` and `Reader` via
  `arrayContaining`. Allows extra labels — fine. But does NOT assert
  *order* or that `View` is present (the test asserts items *under* View
  on L44-46 without asserting View exists). If `View` is absent the assertion
  on L44 returns `undefined` and "passes" the negative assertion vacuously.
  **Practice violation** (gap allows false-positive on Show Thumbnails
  absence when the entire View menu is gone).
- **Parity gap vs PDF spec:** EPUB spec checks `Show TOC` exists; PDF spec
  does not check `Show TOC` is *absent*. Symmetric negative-assertion
  missing on the PDF side. Record in `parity-gaps.md`.

### 2.2 `e2e/menu-book-pdf.spec.ts`

Focus: PDF-focused book window must have Bookmarks, Reader top-level, plus
View → Show Thumbnails and View → Dual Page.

- **L21, L40** — Same hard-coded `waitForTimeout(2500)` and `waitForTimeout(800)`
  pattern as EPUB. Same **practice violation**.
- **L26** — Same `waitForTimeout(500)` settle pre-evaluate. Same observation.
- **L39** — Same swallowed `.catch(() => {})`. Same observation.
- **L43-46** — Asserts top-level contains Bookmarks/Reader; View > Show
  Thumbnails and View > Dual Page defined. Good positive assertions, but
  symmetric negative assertions are missing:
  - No assertion `Show TOC` is *absent* under View (EPUB-only item).
  - No assertion that PDF-only items are gated correctly when window loses
    focus (cross-window state isn't exercised).
  Record in `parity-gaps.md` (asymmetric coverage with EPUB spec).
- **L42** — Single `getApplicationMenu(launched.app)` snapshot, no
  re-poll if the assertion fails. If the menu rebuild straddles the
  800ms wait, this fails with no retry. Use `expect.poll` to wrap.
  **Practice violation**.
- **Shortcut-key vs click-vs-IPC parity:** Neither EPUB nor PDF spec
  exercises the keyboard accelerator path (e.g. Cmd+Shift+T for Show TOC
  if registered). Only menu-tree presence is asserted; the user-facing
  path of pressing the accelerator is untested. Record in `parity-gaps.md`.
- **Format enablement parity table to flag in parity-gaps.md:**

  | Menu item       | PDF spec asserts | EPUB spec asserts |
  |-----------------|------------------|-------------------|
  | Show TOC        | (not checked)    | present           |
  | Show Thumbnails | present          | absent            |
  | Dual Page       | present          | absent            |
  | Bookmarks       | present (top)    | present (top)     |
  | Reader          | present (top)    | present (top)     |

  Gaps: PDF spec should assert `Show TOC` absent (symmetric negative);
  EPUB spec should assert `Bookmarks` submenu items (it only checks the
  top-level label).

### 2.3 `e2e/menu-bookmarks-submenu.spec.ts`

Focus: After invoking Bookmarks → Add Bookmark, the Bookmarks submenu
should reflect the new entry (a label that is not `Add Bookmark`, not
`Show All Bookmarks…`, and not parenthesized placeholder).

- **L25-38** — Renderer-side `saveBook` workaround to inject `syncId`
  because the test importer doesn't run cloud sync. This is a pragmatic
  shim, but it bypasses the production code path that *would* assign a
  syncId (cloud sync engine). If the production path stops setting syncId
  correctly, this test still passes. **Practice violation** /
  **parity gap** — there is no test that exercises the natural
  addBookmark → syncId branch.
- **L40** — `bookPage.waitForTimeout(2500)`. Same timing issue.
- **L52** — `bookPage.waitForTimeout(600)` after focus before reading
  the menu. Same timing issue; use `expect.poll`.
- **L58-59** — `clickMenuItem(...)` is the *only* path under test.
  Shortcut-key (e.g. Cmd+D for Add Bookmark, if registered) and direct
  IPC (`window.electron.<bookmarks-add>`) are NOT exercised. The three
  paths (menu click vs shortcut vs IPC) can diverge if the menu handler
  has extra logic not in the IPC handler. Record in `parity-gaps.md`.
- **L61** — `waitForTimeout(1500)` for "add-bookmark IPC roundtrip + menu
  publish". This is the most timing-sensitive wait in the file (covers an
  IPC round trip + DB write + menu rebuild + re-apply). If it's flaky in
  CI, increase via polling rather than raw timeout. **Practice violation**.
- **L64-69** — Asserts at least one label exists that isn't the static
  items or a placeholder. Weak: doesn't validate the bookmark's *label
  content* (e.g. page-number formatting, truncation) — only that
  *something* was added. If the menu publish path inserts a malformed
  empty-string item, the `labels.filter((l): l is string => !!l)` would
  drop it and the assertion still passes only if ANY good item is present.
  Possible undercoverage. Consider: assert the new label matches a
  format pattern (e.g. `Page \d+` or contains the chapter name).
  **Practice violation** (assertion too weak).
- **No teardown of the added bookmark.** Per-test launch+close handles
  cleanup via tmp userDataDir, but the database row is created and never
  asserted-clean. Not a bug; note for parity-gaps.
- **Menu-item state asynchrony:** This spec is the most exposed to the
  async menu rebuild. If the rebuild has a debounce, raw `waitForTimeout(1500)`
  may be either too short (flake) or wastefully long (slow test). Investigate
  the publish path in `src/main/menu/*` and decide. Potential **bug**
  candidate only if a deterministic event exists that the test could await
  but doesn't.

### 2.4 Cross-spec patterns to log once

- All three specs use the *same* "focus the book window via
  `electronApplication.evaluate` + `BrowserWindow.find(...).focus()`"
  preamble. If this preamble has a bug (e.g. the URL substring match
  is wrong), all three fail in the same way. Consider extracting to
  `e2e/helpers/electron-app.ts` as `focusBookWindow(app, bookId)`.
  Record in `practices-audit.md` (DRY).
- All three swallow the evaluate failure with `.catch(() => {})`.
  Make this explicit: failing focus should fail the test.
- None of the three assert *enabled/disabled* state of menu items, only
  presence/absence. If a menu item is present but disabled (e.g.
  "Add Bookmark" before a book is loaded), the spec wouldn't catch it.
  Parity gap.

---

## 3. Tester ID range

B056-B070 (Tester B-T5). 15 IDs across 3 specs ≈ 5 findings/spec maximum.
Realistic target: 0-3 findings/spec; the bulk should land in
`parity-gaps.md` and `practices-audit.md` (see §2.4).

Filing rules (re-stated from FINDING-TEMPLATE):
- File `.agent-review/full-sweep-B/findings/B0NN-<slug>.md` (zero-padded).
- Frontmatter `reviewer1_agent_type` alternation: B056/B058/... →
  `feature-dev:code-reviewer`; B057/B059/... → `team-reviewer`.
- One finding = one production bug with a real failing/conceivable test.

---

## 4. Test commands

### Build prerequisite

```bash
pnpm --filter rishi-electron build
```

Required because `e2e/helpers/electron-app.ts:12` resolves
`../../out/main/index.js`. There is no `pretest:e2e` hook.

### Run the three specs

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/menu-book-epub.spec.ts
pnpm test:e2e e2e/menu-book-pdf.spec.ts
pnpm test:e2e e2e/menu-bookmarks-submenu.spec.ts
```

### Single-test runs (these specs each contain exactly one test)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/menu-book-epub.spec.ts -g "focused EPUB book window menu"
pnpm test:e2e e2e/menu-book-pdf.spec.ts -g "focused PDF book window menu"
pnpm test:e2e e2e/menu-bookmarks-submenu.spec.ts -g "Bookmarks > recent submenu"
```

### Flake check (Reviewer-1 requirement: ≥3 runs)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/menu-bookmarks-submenu.spec.ts || echo "run $i: FAIL"; done
```

### Discovery sanity

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/menu-book-epub.spec.ts
pnpm test:e2e --list e2e/menu-book-pdf.spec.ts
pnpm test:e2e --list e2e/menu-bookmarks-submenu.spec.ts
```
