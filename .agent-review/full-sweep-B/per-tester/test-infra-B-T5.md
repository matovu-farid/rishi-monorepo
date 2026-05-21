# Test-Infra Backlog — Tester B-T5 (menu-book group)

Items here are infra/helper changes that would let the three specs (and
future menu specs) assert behavior deterministically. No code mods made
in this phase — these are recommendations for a future infra ticket.

## 1. `focusBookWindow(app, bookId)` helper

**Add to:** `apps/rishi-electron/e2e/helpers/electron-app.ts`

Encapsulate the duplicated focus preamble used by all three specs:

```
// pseudo-shape, not committed
export async function focusBookWindow(
  app: ElectronApplication,
  bookId: number
): Promise<void> {
  await app.evaluate(({ BrowserWindow }, id) => {
    const wins = BrowserWindow.getAllWindows()
    const win = wins.find(w => w.webContents.getURL().includes(`/books/${id}`))
    if (!win) throw new Error(`No book window for id=${id}`)
    if (win.isMinimized()) win.restore()
    win.show()
    win.focus()
  }, bookId)
}
```

Crucially: **do not swallow the rejection** (per B060). If focus fails,
the test should fail loudly with a clear message, not pass with stale
menu state. Add `expect.poll` wrapper for post-condition
(`isFocused() === true`) if races persist.

## 2. `waitForMenuShape(app, predicate, opts?)` helper

**Add to:** `apps/rishi-electron/e2e/helpers/electron-app.ts`

Replaces the `waitForTimeout(800)` + `getApplicationMenu(...)` +
`findMenuItem(...)` triplet with a single polling call:

```
// pseudo-shape
export async function waitForMenuShape(
  app: ElectronApplication,
  predicate: (menu: MenuSnapshot) => boolean,
  opts: { timeout?: number, interval?: number } = {}
): Promise<MenuSnapshot> { ... }
```

This eliminates the raw waits from all three specs (`menu-book-epub:41`,
`menu-book-pdf:40`, `menu-bookmarks-submenu:52, 61`).

## 3. Production-side: emit `menu:applied` event after publish

**Touches (do not change in this phase):** `src/main/menu/installMenu.ts`,
`src/main/ipc/menu.ts`.

Add a deterministic "menu-applied" IPC notification fired after
`Menu.setApplicationMenu(...)` returns. Tests can `app.evaluate` a
one-shot listener and `await` it instead of polling. This is the right
long-term fix for the timing issues in `menu-bookmarks-submenu.spec.ts:61`.

Today's `expect.poll` is a strict improvement over raw `waitForTimeout`,
but a sentinel event removes the timing class of bug entirely.

## 4. Bookmark-fixture factory

**Add to:** `apps/rishi-electron/e2e/helpers/electron-app.ts`

`menu-bookmarks-submenu.spec.ts:25-37` hand-rolls a `saveBook` mutation
to inject `syncId`. Wrap as `seedBookmarkableBook(page, opts)` so future
specs don't recreate the bypass and the production-path-coverage gap is
visible in one place (parity-gaps §3).

## 5. Top-level menu snapshot test (regression net)

Add a single spec that asserts the full *shape* of the application menu
in each context (Library, EPUB book, PDF book, AZW3 book if applicable).
A focused snapshot — keyed on `(label, submenuLabels)` only, no
positions, no roles — would catch the entire class of "View submenu
disappears in EPUB context" and "Show TOC leaks into PDF" regressions in
one place. Today's coverage is scattered across three specs and misses
both via different mechanisms (B056, B057).

## 6. Flake-detection wrapper

`menu-bookmarks-submenu.spec.ts` is the most timing-sensitive of the
three (IPC round-trip + DB write + publish + re-apply behind a raw
1500ms wait). Per the plan §4, a 3x loop check is the suggested
flake-detection mechanism. Suggest adding `pnpm test:e2e:flake-check`
script that runs the menu suite 3 times in headed mode and surfaces
intermittent failures.

## 7. Menu enabled/disabled assertion helper

`findMenuItem` returns presence; no helper returns enabled-state. Add
`assertMenuItemEnabled(menu, path, expected)` so future specs can pin
the enabled/disabled contract called out in parity-gaps §4.
