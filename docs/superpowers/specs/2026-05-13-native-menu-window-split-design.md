# Native menu + window split

**Status:** Draft
**Owner:** matovu-farid
**Date:** 2026-05-13
**App:** `apps/rishi-electron`

## Problem

The reader's top toolbar (TOC, thumbnails, bookmark, back-to-library) is an in-window floating bar that auto-hides after 2 seconds and only shows on hover near the top of the window. It overlaps the reading area, is invisible when needed, and clones what should be OS-native menu items.

We want reader actions to live on the OS-native menu bar instead, and to split the app into separate windows — one Library, one per open book — so each window's menu can reflect what that window does.

## Goals

1. Delete the in-window reader toolbar. All its actions move to the OS-native menu (macOS menu bar, Windows/Linux in-window menu).
2. Library and each open book are independent `BrowserWindow`s. The focused window's identity determines the menu shown.
3. Reader features that were toolbar-only (TOC, thumbnails, bookmark, dual-page, read-aloud, chat) get accelerators (keyboard shortcuts) for power users.
4. No regression in: file-association open, single-instance lock, OAuth deep-link flow, auth session sync across windows, theme propagation.

## Non-goals

- Per-window persisted geometry beyond what macOS state restoration gives for free.
- Drag-out tabs / merge windows.
- Tear-off TOC/Thumbnails panels as their own windows.
- New menu items unrelated to today's toolbar (no "Print", no "Export as image", etc.).
- Replacing the in-app `Sheet`-based TOC and Thumbnail sidebars — the menu items toggle the existing panels; they don't reimplement them.

## User-facing behavior

### Windows

- **Library window** — singleton. Created on app launch. Title: *"Library — Rishi"*. Loads route `/`.
- **Book window** — one per open book. Title: book title. Loads route `/books/$id`. Hides the route `/` entirely (router doesn't register the library route in book windows).
- Clicking a library row opens (or focuses) the book's window. Library row no longer navigates within the same window.
- File-association open (`open-file` on macOS, second-instance argv on Win/Linux) opens a book window.
- Closing the library window keeps book windows open. Closing the last book window does not quit (library remains, or app is dock-resident on mac).
- macOS: clicking the dock icon when no windows are visible reopens the library window (existing pattern preserved).

### Menus

Same logical items either OS; Electron places them on the macOS system bar vs. inside the window automatically.

**Library window menu**

| Top-level | Items |
|---|---|
| App (mac) / File | About Rishi, Preferences (mac), —, Quit |
| File | Import Book… (⌘O), Open Recent ▸, —, Close Window (⌘W) |
| Edit | Undo / Redo / Cut / Copy / Paste / Select All (role-based) |
| View | Toggle Theme (⌘⇧T), Reload (⌘R, dev only), Toggle DevTools (⌥⌘I, dev only) |
| Window | Minimize (⌘M), Zoom, —, Library (⌘1), —, *open book titles*, —, Bring All to Front (mac) |
| Help | Documentation, Report Issue |

**Book window menu** (overlays library menu with reader-specific items)

| Top-level | Items |
|---|---|
| File | Import Book… (⌘O), Open Recent ▸, —, **Close Book** (⌘W) |
| Edit | role-based |
| View | Toggle Theme (⌘⇧T), —, **Show TOC** (⌘T) [checkable], **Show Thumbnails** (⌘\) [checkable, PDF only], —, **Dual Page** (⌘⇧D) [checkable, PDF only], —, Zoom In / Out / Reset (PDF only) |
| **Bookmarks** | **Add Bookmark** (⌘D), Show All Bookmarks…, —, *Recent Bookmarks ▸* |
| **Reader** | **Read Aloud** (⌘R) [toggle: starts/stops], **Voice Chat** (⌘⇧V), —, **Open Chat** (⌘K) |
| Window | Minimize, Zoom, —, Library (⌘1), —, *open book titles* (this book checked), —, Bring All to Front |
| Help | Documentation, Report Issue |

Format-only items (`Show Thumbnails`, `Dual Page`, Zoom) are **hidden** (not just disabled) when the focused book window is not PDF.

### Keyboard shortcuts retained from old toolbar

- ⌘T: open TOC
- ⌘\: open Thumbnails (PDF)
- ⌘D: add bookmark
- ⌘⇧D: toggle dual-page (PDF)
- ⌘R: read aloud
- ⌘K: open chat
- ⌘⇧V: voice chat
- ⌘1: focus library window
- ⌘W: close current window
- Back-to-library button (no accelerator today): **removed**. Replaced by Window → Library (⌘1).

## Architecture

### Module map (new)

```
apps/rishi-electron/
├── src/main/
│   ├── menu/
│   │   ├── menuBuilder.ts        # pure builder: state -> MenuItemConstructorOptions[]
│   │   ├── menuBuilder.test.ts   # unit tests (vitest)
│   │   └── accelerators.ts       # accelerator string constants, OS-aware
│   ├── windows/
│   │   ├── windowManager.ts      # owns library window + book window map
│   │   ├── windowManager.test.ts # unit tests
│   │   └── windowIdentity.ts     # injected via additionalArguments; renderer reads
│   └── ipc/
│       └── menuCommands.ts       # wires menu clicks -> webContents.send('menu:command')
└── src/renderer/src/
    ├── hooks/
    │   ├── useMenuCommands.ts    # single ipc listener, dispatches to stores
    │   ├── useWindowIdentity.ts  # reads identity from query string / preload
    │   └── useMenuContext.ts     # publishes format/state changes to main
    └── routes/
        └── __root.tsx            # mounts useMenuCommands once per window
```

### Files modified

| Path | Change |
|---|---|
| `src/main/index.ts` | replace single `createWindow()` with `windowManager.openLibrary()`; route `open-file` and `second-instance` through `windowManager.openBook()` |
| `src/preload/index.ts` | expose `windowIdentity` (from `additionalArguments`) and `onMenuCommand`, `setMenuContext` |
| `src/renderer/src/components/reader/ReaderToolbar.tsx` | **deleted** |
| `src/renderer/src/components/BackButton.tsx` | **deleted** (no remaining callers after toolbar removal) |
| `src/renderer/src/components/pdf/hooks/useSetupMenu.tsx` | **deleted** (native menu owns the shortcut) |
| `src/renderer/src/components/pdf/components/pdf.tsx` | drop the `<ReaderToolbar>` block + its imports |
| `src/renderer/src/components/epub/EpubView.tsx` | same |
| `src/renderer/src/components/mobi/MobiView.tsx` | same |
| `src/renderer/src/components/djvu/DjvuView.tsx` | same |
| `src/renderer/src/routes/index.lazy.tsx` (library) | library row `onClick` → `window.electron.openBook(bookId)` instead of router `navigate` |
| `src/renderer/src/routes/__root.tsx` | mount `useMenuCommands()`; guard route tree by window identity |

### Window manager (main)

```ts
type WindowKind =
  | { kind: 'library' }
  | { kind: 'book'; bookId: number; format: 'pdf'|'epub'|'mobi'|'djvu' }

class WindowManager {
  library: BrowserWindow | null
  books: Map<number, BrowserWindow>   // bookId -> window

  openLibrary(): BrowserWindow            // creates or focuses
  openBook(bookId: number, filepath?: string): Promise<BrowserWindow>
  closeBook(bookId: number): void
  getFocusedKind(): WindowKind | null
  getBookFormat(bookId: number): Promise<'pdf'|'epub'|'mobi'|'djvu'>
  allWindows(): BrowserWindow[]
}
```

- `openBook` resolves format via existing `getBook` IPC repo; passes `?window=book&bookId=N` on the loaded URL and `--window-identity=book:N` in `additionalArguments`. Renderer reads the latter via `process.argv` (since contextIsolation is on, preload exposes it).
- On `BrowserWindow.on('closed')`, the manager updates its map and broadcasts `window:closed` to the remaining windows so their Window menu updates.

### Menu builder

```ts
type MenuContext =
  | { kind: 'library'; recentBooks: RecentBook[]; openBookTitles: OpenBookTitle[]; theme: Theme }
  | { kind: 'book'; bookId: number; format: Format; title: string;
      tocOpen: boolean; thumbsOpen: boolean; dualPage: boolean;
      isReading: boolean; recentBooks: RecentBook[]; openBookTitles: OpenBookTitle[];
      bookmarks: BookmarkSummary[]; theme: Theme }

function buildMenu(ctx: MenuContext): MenuItemConstructorOptions[]
```

- Pure function. Unit-tested via vitest in `menuBuilder.test.ts`.
- `click` handlers are bound by the caller (the manager) to commands, not actions — commands are dispatched as `menu:command` via the focused window's `webContents`.
- Menu is rebuilt on `browser-window-focus` **only if** the focused window's identity *kind* changes (`library` ↔ `book`) or its context payload's hash changes. Identity hash diffing prevents flicker on plain focus toggles.

### IPC contract

| Channel | Direction | Payload | Purpose |
|---|---|---|---|
| `menu:command` | main → renderer | `{ command: 'addBookmark' \| 'toggleTOC' \| 'toggleThumbnails' \| 'toggleDualPage' \| 'readAloudToggle' \| 'openChat' \| 'voiceChat' \| 'toggleTheme' \| 'importBook' \| 'openRecent' \| ... ; arg?: unknown }` | Forwards menu clicks to the focused window |
| `menu:setContext` | renderer → main | `Partial<MenuContext>` (book window's reader state) | Renderer reports format/TTS/dual-page state changes so menu enable/check state stays current |
| `window:openBook` | renderer → main | `{ bookId: number }` | Library row click → opens or focuses a book window |
| `window:closeBook` | renderer → main | `{ bookId: number }` | Menu "Close Book" → closes that book window |
| `window:focusLibrary` | renderer → main | `{}` | Menu "Library" / ⌘1 |
| `window:list` | renderer → main (invoke) | `{}` → `{ openBooks: OpenBookTitle[] }` | Window-menu population |
| `window:event` | main → renderer (broadcast) | `{ kind: 'opened'\|'closed'\|'titleChanged'; bookId: number; title?: string }` | All windows update Window-menu entries |

`theme:changed` and `session-changed` already exist; both will be broadcast to every window via `getAllWindows()`.

### Renderer wiring

- `useMenuCommands(identity)` mounted in `__root.tsx`. Single listener; switch on `command`. For book-window-only commands, asserts identity is `book`.
- Reader components publish state via `useMenuContext()` — calls `window.electron.setMenuContext({ tocOpen, thumbsOpen, dualPage, isReading })` whenever those values change.
- Library row click handler: `window.electron.openBook(bookId)`. The library `/books/$id` route is removed from book windows (it stays in library window for legacy hash links, but the row click no longer uses it).

### Window identity (renderer-side)

Preload exposes:
```ts
window.electron.windowIdentity: { kind: 'library' } | { kind: 'book'; bookId: number }
```
Sourced from `additionalArguments` parsed once at preload load.

TanStack Router routes are file-based and registered at compile time; we don't unregister routes per window. Instead, the root route (`__root.tsx`) reads `windowIdentity` and applies guards:
- **Library window** on `/` → renders the library.
- **Library window** on `/books/$id` (legacy hash link) → calls `openBook(id)` to spawn a book window, then navigates the library window back to `/`.
- **Book window** boots directly to `/books/$id` from the loaded URL. If it ever lands on `/`, the root guard redirects it to its own `/books/$bookId` from the injected identity.

### State stays where it is

- Bookmarks list: SQLite, read via existing `bookmarks:list` IPC.
- Recent books: SQLite, read via `books:list` IPC with `ORDER BY last_read_at DESC LIMIT N` (new query — add to existing `books` repo).
- Theme: existing Zustand `themeStore` + broadcast.
- Reader state (TOC open, thumbs open, dual-page, isReading): existing Zustand stores (`pdfStore`, etc.); we just publish change events to main.

### Single-instance behavior

- App requests single-instance lock (existing).
- `second-instance` with a file arg → `windowManager.openBook(byPath: filepath)`. The window manager resolves bookId by filepath or imports if new (matches existing `open-file` semantics).
- `second-instance` with no args → focuses library window.

## Testing strategy

### Unit tests (vitest, existing harness)

- `menuBuilder.test.ts`:
  - Builds library menu — asserts items and accelerators.
  - Builds book menu (PDF) — asserts Show Thumbnails + Dual Page present.
  - Builds book menu (EPUB) — asserts Show Thumbnails + Dual Page **absent**.
  - Builds book menu (MOBI/DJVU) — asserts Show Thumbnails + Dual Page **absent**.
  - Checkable items reflect state (`tocOpen: true` → `checked: true`).
  - Theme item label flips between "Light Mode" / "Dark Mode" by current theme.
  - Recent submenu populated from input array (preserves order, caps at 10).
- `windowManager.test.ts`:
  - `openBook` creates a new window when bookId is unknown.
  - `openBook` focuses an existing window when bookId is known.
  - `closeBook` removes the window from the map.
  - `getFocusedKind` returns `library` when library is focused, `book` when book is focused.

### Integration tests (Playwright + ElectronApplication, existing harness)

New e2e files in `apps/rishi-electron/e2e/`:

- `e2e/menu-library.spec.ts`:
  - Launch app → library window exists.
  - Menu (via `app.evaluate`) → has File, View, Window, Help.
  - Library window menu has no Bookmarks or Reader top-level.
- `e2e/menu-book-pdf.spec.ts`:
  - Import PDF → open it → second window appears.
  - Book window's menu has Bookmarks and Reader top-level.
  - PDF-only items (Show Thumbnails, Dual Page) present.
- `e2e/menu-book-epub.spec.ts`:
  - Import EPUB → open it → menu has Bookmarks + Reader but no Thumbnails/Dual Page.
- `e2e/window-split.spec.ts`:
  - Open two books → two book windows + one library window (3 total).
  - Close library → book windows remain.
  - Open the same book twice → only one book window for that bookId; focused.
- `e2e/menu-commands.spec.ts`:
  - Open PDF → trigger Bookmarks → Add Bookmark from menu (programmatic click via `app.evaluate(Menu.getApplicationMenu()...)`) → bookmark count increases via DB.
  - Trigger View → Show TOC → TOC `Sheet` opens in the renderer.
  - Trigger Reader → Read Aloud → `usePlayerStore.playingState === 'playing'`.
- `e2e/window-identity.spec.ts`:
  - Library window has `window.electron.windowIdentity === { kind: 'library' }`.
  - Book window has `window.electron.windowIdentity === { kind: 'book', bookId: <n> }`.
- `e2e/no-toolbar.spec.ts`:
  - Open PDF reader → assert `[data-tour="reader-toolbar"]` does **not** exist in DOM.

### Test ergonomics

- Extend `e2e/helpers/electron-app.ts` with `getAllWindows(app: ElectronApplication)`, `getFocusedMenu(app): Promise<MenuShape>` (round-trips through `app.evaluate` to read the focused `Menu.getApplicationMenu()` tree), and `clickMenuItem(app, path: string[])`.
- `MenuShape` is a serialisable shape: `{ label, role?, accelerator?, type?, checked?, visible?, enabled?, submenu? }`.

### Manual smoke before shipping

1. Launch on macOS — menu bar shows correct items, switches between Library and Book on focus.
2. Launch on Windows — in-window menu shows same items in the same order.
3. ⌘O → import book → opens book window.
4. ⌘W in book window → closes it (not the app).
5. ⌘1 from book window → focuses library.
6. ⌘D adds a bookmark; visible in `Show All Bookmarks` and on disk.
7. ⌘R toggles read-aloud.
8. Theme toggle from library window propagates to open book windows.
9. Sign out / sign in → all windows reflect new session.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Menu flicker on every focus change | Build only on identity-kind change or context hash change |
| Renderer↔main IPC roundtrip latency makes menu items feel sluggish | All menu commands are intent-only — renderer dispatches immediately, no waits |
| Multiple windows duplicate Sentry / OpenTelemetry init | Init runs in main process only; renderers reuse existing single init |
| Bookmark / read-aloud actions executed against the wrong book | Identity check in `useMenuCommands`: every book-only command asserts current `windowIdentity.kind === 'book'` and uses its `bookId` |
| `pdfStore` is module-scoped (singleton in each renderer) — but two book windows share no state; each is its own renderer | This is correct. Confirm before phase 3. |
| Tests that assumed the toolbar exists (e.g., `pdf-toolbar-sticky.spec.ts`) will break | Replace those specs with menu-equivalent specs (listed above). Delete the old ones in the same PR as the toolbar removal. |
| File-association → window resolution by filepath: edge case where the same file path was imported with different bookIds | `openBook(byPath)` resolves via `books WHERE filepath = ? ORDER BY id LIMIT 1`. If not found, falls through to existing import flow, which creates the book row, then opens the window. |
| Linux global menu (Unity) | Out of scope; Electron will render in-window on those DEs |

## Phased rollout

Each phase is shippable independently and TDD-driven.

### Phase 1 — Menu plumbing (no UI removal yet)

- Add `menuBuilder.ts`, `windowManager.ts` (single-window mode only — `openLibrary` returns existing window, `openBook` no-op).
- Add `menu:command` IPC and `useMenuCommands` hook.
- Native menu installed; toolbar still in place. Both fire the same actions.
- Unit + a small set of integration tests asserting menu items and that menu clicks dispatch the same effects as the toolbar buttons.

### Phase 2 — Drop the in-window toolbar

- Delete `ReaderToolbar`, `BackButton`, `useSetupMenu` and their callers' header blocks.
- Update / delete the existing toolbar-dependent specs (`pdf-toolbar-sticky.spec.ts` etc.) in the same PR.
- Verify parity with phase-1 menu commands.

### Phase 3 — Window split

- `windowManager.openBook` creates real new windows.
- Library row click → IPC → new book window.
- Window menu lists open books; ⌘1 focuses library; ⌘W closes book.
- Window identity injected via `additionalArguments`; book windows hide library route.

### Phase 4 — Polish

- File → Open Recent (driven by `books.last_read_at`).
- Bookmarks → Recent Bookmarks submenu.
- Window-state restoration for last library size/position (defer book windows).

## TDD order within each phase

1. Write failing unit test for the smallest piece (e.g., `menuBuilder` returns the correct top-level array for library).
2. Implement until green.
3. Write next failing test (e.g., book menu hides PDF-only items for EPUB).
4. Repeat.
5. After unit tests are green, write the phase's integration test(s) and drive code until they pass.

Playwright tests are added at integration boundaries — they don't replace unit tests; they assert behavior end-to-end through the real BrowserWindow.

## Spec acceptance criteria

- [ ] Native menu visible on launch (mac and win).
- [ ] All toolbar functions reachable from menu with accelerators.
- [ ] `ReaderToolbar` deleted; no references remain.
- [ ] Two open books → two book windows + one library window.
- [ ] Closing library doesn't quit; closing book doesn't close library.
- [ ] Format-only menu items hidden for non-matching formats.
- [ ] All new Playwright specs pass on macOS CI.
- [ ] No regression in existing specs that weren't toolbar-coupled.
