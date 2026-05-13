# Native menu + window split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the auto-hiding in-window reader toolbar with OS-native menu items, and split the app into a Library window plus one window per open book.

**Architecture:** New `src/main/menu/` and `src/main/windows/` modules in the Electron main process. A pure `menuBuilder` produces `MenuItemConstructorOptions[]` from a typed context. A `windowManager` owns the library window and a `Map<bookId, BrowserWindow>` of book windows. Menu clicks are forwarded to the focused window via a single `menu:command` IPC channel; a `useMenuCommands` hook in the renderer dispatches commands to the existing stores. Window identity (`{kind:'library'}` or `{kind:'book',bookId}`) is injected at `BrowserWindow` creation via `webPreferences.additionalArguments` and exposed by preload.

**Tech Stack:** Electron 38, electron-vite, TypeScript, React, TanStack Router, Zustand, vitest, Playwright (`@playwright/test` with `_electron`).

**Spec:** `docs/superpowers/specs/2026-05-13-native-menu-window-split-design.md`

---

## Working directory

All commands run from `apps/rishi-electron/` unless otherwise noted. Set the directory explicitly in commit blocks (worktrees etc.).

## Conventions

- Strict TypeScript. No `any` in new files.
- Test-first: write the failing test, run it, see it fail, then implement.
- Commit every task (failing-test commit + green-implementation commit is fine; one combined commit per logical unit is also fine — pick the smaller unit).
- After Phase 1, the toolbar still exists alongside the menu. Don't delete it until Phase 2.

---

# Phase 1 — Menu plumbing (toolbar stays)

Goal: native menu installed on the (single) library window. Menu clicks dispatch through IPC and fire the same actions the toolbar buttons do. Toolbar still works.

---

## Task 1: Accelerator constants

**Files:**
- Create: `apps/rishi-electron/src/main/menu/accelerators.ts`
- Test: `apps/rishi-electron/src/main/menu/accelerators.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/main/menu/accelerators.test.ts
import { describe, it, expect } from 'vitest'
import { ACCELERATORS } from './accelerators'

describe('ACCELERATORS', () => {
  it('uses CmdOrCtrl prefix so Electron does the OS mapping', () => {
    expect(ACCELERATORS.importBook).toBe('CmdOrCtrl+O')
    expect(ACCELERATORS.closeWindow).toBe('CmdOrCtrl+W')
    expect(ACCELERATORS.focusLibrary).toBe('CmdOrCtrl+1')
    expect(ACCELERATORS.toggleTheme).toBe('CmdOrCtrl+Shift+T')
    expect(ACCELERATORS.toggleTOC).toBe('CmdOrCtrl+T')
    expect(ACCELERATORS.toggleThumbnails).toBe('CmdOrCtrl+\\')
    expect(ACCELERATORS.toggleDualPage).toBe('CmdOrCtrl+Shift+D')
    expect(ACCELERATORS.addBookmark).toBe('CmdOrCtrl+D')
    expect(ACCELERATORS.readAloud).toBe('CmdOrCtrl+R')
    expect(ACCELERATORS.voiceChat).toBe('CmdOrCtrl+Shift+V')
    expect(ACCELERATORS.openChat).toBe('CmdOrCtrl+K')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/rishi-electron
pnpm test src/main/menu/accelerators.test.ts
```
Expected: FAIL — module does not exist.

- [ ] **Step 3: Write minimal implementation**

```ts
// src/main/menu/accelerators.ts
export const ACCELERATORS = {
  importBook: 'CmdOrCtrl+O',
  closeWindow: 'CmdOrCtrl+W',
  focusLibrary: 'CmdOrCtrl+1',
  toggleTheme: 'CmdOrCtrl+Shift+T',
  toggleTOC: 'CmdOrCtrl+T',
  toggleThumbnails: 'CmdOrCtrl+\\',
  toggleDualPage: 'CmdOrCtrl+Shift+D',
  addBookmark: 'CmdOrCtrl+D',
  readAloud: 'CmdOrCtrl+R',
  voiceChat: 'CmdOrCtrl+Shift+V',
  openChat: 'CmdOrCtrl+K'
} as const

export type AcceleratorKey = keyof typeof ACCELERATORS
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pnpm test src/main/menu/accelerators.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/menu/accelerators.ts apps/rishi-electron/src/main/menu/accelerators.test.ts
git commit -m "feat(menu): add accelerator constants module"
```

---

## Task 2: Menu command vocabulary + types

**Files:**
- Create: `apps/rishi-electron/src/main/menu/commands.ts`
- Test: `apps/rishi-electron/src/main/menu/commands.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/main/menu/commands.test.ts
import { describe, it, expectTypeOf, expect } from 'vitest'
import type { MenuCommand, MenuContext } from './commands'

describe('menu command vocabulary', () => {
  it('union covers every action the menu can emit', () => {
    const all: MenuCommand[] = [
      { command: 'importBook' },
      { command: 'openRecent', arg: { bookId: 1 } },
      { command: 'closeWindow' },
      { command: 'focusLibrary' },
      { command: 'toggleTheme' },
      { command: 'toggleTOC' },
      { command: 'toggleThumbnails' },
      { command: 'toggleDualPage' },
      { command: 'addBookmark' },
      { command: 'showAllBookmarks' },
      { command: 'jumpToBookmark', arg: { bookmarkId: 9 } },
      { command: 'readAloudToggle' },
      { command: 'voiceChat' },
      { command: 'openChat' },
      { command: 'openHelp' },
      { command: 'reportIssue' },
      { command: 'about' }
    ]
    expect(all.length).toBeGreaterThan(0)
  })

  it('library context omits book-specific fields', () => {
    const ctx: MenuContext = {
      kind: 'library',
      theme: 'light',
      recentBooks: [],
      openBookTitles: []
    }
    expectTypeOf(ctx.kind).toEqualTypeOf<'library'>()
  })

  it('book context carries reader state', () => {
    const ctx: MenuContext = {
      kind: 'book',
      bookId: 7,
      format: 'pdf',
      title: 'X',
      tocOpen: false,
      thumbsOpen: false,
      dualPage: false,
      isReading: false,
      theme: 'light',
      recentBooks: [],
      openBookTitles: [{ bookId: 7, title: 'X' }],
      bookmarks: []
    }
    expectTypeOf(ctx.kind).toEqualTypeOf<'book'>()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pnpm test src/main/menu/commands.test.ts
```
Expected: FAIL — module does not exist.

- [ ] **Step 3: Write implementation**

```ts
// src/main/menu/commands.ts
export type BookFormat = 'pdf' | 'epub' | 'mobi' | 'djvu'
export type Theme = 'light' | 'dark'

export interface RecentBook { bookId: number; title: string }
export interface OpenBookTitle { bookId: number; title: string }
export interface BookmarkSummary { id: number; label: string; location: string }

export type MenuCommand =
  | { command: 'importBook' }
  | { command: 'openRecent'; arg: { bookId: number } }
  | { command: 'closeWindow' }
  | { command: 'focusLibrary' }
  | { command: 'toggleTheme' }
  | { command: 'toggleTOC' }
  | { command: 'toggleThumbnails' }
  | { command: 'toggleDualPage' }
  | { command: 'addBookmark' }
  | { command: 'showAllBookmarks' }
  | { command: 'jumpToBookmark'; arg: { bookmarkId: number } }
  | { command: 'readAloudToggle' }
  | { command: 'voiceChat' }
  | { command: 'openChat' }
  | { command: 'openHelp' }
  | { command: 'reportIssue' }
  | { command: 'about' }

export type LibraryMenuContext = {
  kind: 'library'
  theme: Theme
  recentBooks: RecentBook[]
  openBookTitles: OpenBookTitle[]
}

export type BookMenuContext = {
  kind: 'book'
  bookId: number
  format: BookFormat
  title: string
  tocOpen: boolean
  thumbsOpen: boolean
  dualPage: boolean
  isReading: boolean
  theme: Theme
  recentBooks: RecentBook[]
  openBookTitles: OpenBookTitle[]
  bookmarks: BookmarkSummary[]
}

export type MenuContext = LibraryMenuContext | BookMenuContext
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pnpm test src/main/menu/commands.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/menu/commands.ts apps/rishi-electron/src/main/menu/commands.test.ts
git commit -m "feat(menu): add command + context type vocabulary"
```

---

## Task 3: Menu builder — library shape

**Files:**
- Create: `apps/rishi-electron/src/main/menu/menuBuilder.ts`
- Test: `apps/rishi-electron/src/main/menu/menuBuilder.test.ts`

The builder produces a `MenuItemConstructorOptions[]` describing top-level menus. Click handlers in tests use a `dispatch` parameter so the test can assert payloads without involving Electron's `Menu` class.

- [ ] **Step 1: Write the failing test**

```ts
// src/main/menu/menuBuilder.test.ts
import { describe, it, expect, vi } from 'vitest'
import type { MenuCommand, MenuContext } from './commands'
import { buildMenu, findItem } from './menuBuilder'

const libraryCtx: MenuContext = {
  kind: 'library',
  theme: 'light',
  recentBooks: [],
  openBookTitles: []
}

describe('buildMenu — library', () => {
  it('has top-level File, Edit, View, Window, Help', () => {
    const tpl = buildMenu(libraryCtx, vi.fn())
    const labels = tpl.map((m) => m.label ?? m.role)
    expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View', 'Window', 'Help']))
  })

  it('does NOT include Bookmarks or Reader top-level', () => {
    const tpl = buildMenu(libraryCtx, vi.fn())
    const labels = tpl.map((m) => m.label)
    expect(labels).not.toContain('Bookmarks')
    expect(labels).not.toContain('Reader')
  })

  it('File > Import Book dispatches { command: "importBook" }', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(libraryCtx, dispatch)
    const importItem = findItem(tpl, ['File', 'Import Book…'])
    expect(importItem).toBeDefined()
    expect(importItem!.accelerator).toBe('CmdOrCtrl+O')
    importItem!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'importBook' })
  })

  it('Window > Library dispatches focusLibrary with CmdOrCtrl+1', () => {
    const dispatch = vi.fn()
    const tpl = buildMenu(libraryCtx, dispatch)
    const libItem = findItem(tpl, ['Window', 'Library'])
    expect(libItem!.accelerator).toBe('CmdOrCtrl+1')
    libItem!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'focusLibrary' })
  })

  it('View > Toggle Theme label reflects current theme', () => {
    const dark: MenuContext = { ...libraryCtx, theme: 'dark' }
    const labelLight = findItem(buildMenu(libraryCtx, vi.fn()), ['View', 'Switch to Dark Mode'])
    const labelDark = findItem(buildMenu(dark, vi.fn()), ['View', 'Switch to Light Mode'])
    expect(labelLight).toBeDefined()
    expect(labelDark).toBeDefined()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pnpm test src/main/menu/menuBuilder.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Write implementation**

```ts
// src/main/menu/menuBuilder.ts
import type { MenuItemConstructorOptions } from 'electron'
import { ACCELERATORS } from './accelerators'
import type { MenuCommand, MenuContext } from './commands'

export type Dispatch = (c: MenuCommand) => void

export function buildMenu(ctx: MenuContext, dispatch: Dispatch): MenuItemConstructorOptions[] {
  const isMac = process.platform === 'darwin'
  const fire = (c: MenuCommand) => () => dispatch(c)

  const fileMenu: MenuItemConstructorOptions = {
    label: 'File',
    submenu: [
      { label: 'Import Book…', accelerator: ACCELERATORS.importBook, click: fire({ command: 'importBook' }) },
      { label: 'Open Recent', submenu: buildRecentSubmenu(ctx.recentBooks, dispatch) },
      { type: 'separator' },
      ctx.kind === 'book'
        ? { label: 'Close Book', accelerator: ACCELERATORS.closeWindow, click: fire({ command: 'closeWindow' }) }
        : { label: 'Close Window', accelerator: ACCELERATORS.closeWindow, role: 'close' }
    ]
  }

  const editMenu: MenuItemConstructorOptions = {
    label: 'Edit',
    submenu: [
      { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' },
      { type: 'separator' }, { role: 'selectAll' }
    ]
  }

  const themeLabel = ctx.theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'
  const viewSubmenu: MenuItemConstructorOptions[] = [
    { label: themeLabel, accelerator: ACCELERATORS.toggleTheme, click: fire({ command: 'toggleTheme' }) }
  ]
  if (ctx.kind === 'book') {
    viewSubmenu.push(
      { type: 'separator' },
      { label: 'Show TOC', accelerator: ACCELERATORS.toggleTOC, type: 'checkbox', checked: ctx.tocOpen, click: fire({ command: 'toggleTOC' }) }
    )
    if (ctx.format === 'pdf') {
      viewSubmenu.push(
        { label: 'Show Thumbnails', accelerator: ACCELERATORS.toggleThumbnails, type: 'checkbox', checked: ctx.thumbsOpen, click: fire({ command: 'toggleThumbnails' }) },
        { type: 'separator' },
        { label: 'Dual Page', accelerator: ACCELERATORS.toggleDualPage, type: 'checkbox', checked: ctx.dualPage, click: fire({ command: 'toggleDualPage' }) }
      )
    }
  }

  const windowSubmenu: MenuItemConstructorOptions[] = [
    { role: 'minimize' }, { role: 'zoom' },
    { type: 'separator' },
    { label: 'Library', accelerator: ACCELERATORS.focusLibrary, click: fire({ command: 'focusLibrary' }) }
  ]
  if (ctx.openBookTitles.length > 0) {
    windowSubmenu.push({ type: 'separator' })
    for (const b of ctx.openBookTitles) {
      windowSubmenu.push({
        label: b.title,
        type: 'checkbox',
        checked: ctx.kind === 'book' && ctx.bookId === b.bookId,
        click: fire({ command: 'openRecent', arg: { bookId: b.bookId } })
      })
    }
  }
  if (isMac) {
    windowSubmenu.push({ type: 'separator' }, { role: 'front' })
  }

  const helpMenu: MenuItemConstructorOptions = {
    label: 'Help',
    role: 'help',
    submenu: [
      { label: 'Documentation', click: fire({ command: 'openHelp' }) },
      { label: 'Report Issue', click: fire({ command: 'reportIssue' }) }
    ]
  }

  const top: MenuItemConstructorOptions[] = []
  if (isMac) {
    top.push({
      label: 'Rishi',
      submenu: [
        { label: 'About Rishi', click: fire({ command: 'about' }) },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
        { type: 'separator' }, { role: 'quit' }
      ]
    })
  }
  top.push(fileMenu, editMenu, { label: 'View', submenu: viewSubmenu })
  if (ctx.kind === 'book') {
    top.push(buildBookmarksMenu(ctx, dispatch), buildReaderMenu(ctx, dispatch))
  }
  top.push({ label: 'Window', role: 'windowMenu', submenu: windowSubmenu }, helpMenu)
  return top
}

function buildRecentSubmenu(recent: { bookId: number; title: string }[], dispatch: Dispatch): MenuItemConstructorOptions[] {
  if (recent.length === 0) return [{ label: '(no recent books)', enabled: false }]
  return recent.slice(0, 10).map((r) => ({
    label: r.title,
    click: () => dispatch({ command: 'openRecent', arg: { bookId: r.bookId } })
  }))
}

function buildBookmarksMenu(ctx: Extract<MenuContext, { kind: 'book' }>, dispatch: Dispatch): MenuItemConstructorOptions {
  const recent: MenuItemConstructorOptions[] = ctx.bookmarks.slice(0, 10).map((b) => ({
    label: b.label,
    click: () => dispatch({ command: 'jumpToBookmark', arg: { bookmarkId: b.id } })
  }))
  return {
    label: 'Bookmarks',
    submenu: [
      { label: 'Add Bookmark', accelerator: ACCELERATORS.addBookmark, click: () => dispatch({ command: 'addBookmark' }) },
      { label: 'Show All Bookmarks…', click: () => dispatch({ command: 'showAllBookmarks' }) },
      { type: 'separator' },
      ...(recent.length > 0 ? recent : [{ label: '(no bookmarks yet)', enabled: false }])
    ]
  }
}

function buildReaderMenu(ctx: Extract<MenuContext, { kind: 'book' }>, dispatch: Dispatch): MenuItemConstructorOptions {
  return {
    label: 'Reader',
    submenu: [
      { label: ctx.isReading ? 'Stop Read Aloud' : 'Read Aloud',
        accelerator: ACCELERATORS.readAloud,
        click: () => dispatch({ command: 'readAloudToggle' }) },
      { label: 'Voice Chat', accelerator: ACCELERATORS.voiceChat, click: () => dispatch({ command: 'voiceChat' }) },
      { type: 'separator' },
      { label: 'Open Chat', accelerator: ACCELERATORS.openChat, click: () => dispatch({ command: 'openChat' }) }
    ]
  }
}

export function findItem(
  template: MenuItemConstructorOptions[],
  path: string[]
): MenuItemConstructorOptions | undefined {
  let cursor: MenuItemConstructorOptions[] | undefined = template
  let found: MenuItemConstructorOptions | undefined
  for (const label of path) {
    if (!cursor) return undefined
    found = cursor.find((m) => m.label === label)
    if (!found) return undefined
    cursor = (found.submenu as MenuItemConstructorOptions[]) ?? undefined
  }
  return found
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pnpm test src/main/menu/menuBuilder.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/menu/menuBuilder.ts apps/rishi-electron/src/main/menu/menuBuilder.test.ts
git commit -m "feat(menu): library menu shape with theme + Window > Library"
```

---

## Task 4: Menu builder — book menu format gating

**Files:**
- Modify: `apps/rishi-electron/src/main/menu/menuBuilder.test.ts` (extend with book cases)

- [ ] **Step 1: Write the failing test (append)**

```ts
// append to src/main/menu/menuBuilder.test.ts
import type { BookMenuContext } from './commands'

const pdfCtx: BookMenuContext = {
  kind: 'book', bookId: 1, format: 'pdf', title: 'PDF Book',
  tocOpen: false, thumbsOpen: false, dualPage: false, isReading: false,
  theme: 'light', recentBooks: [], openBookTitles: [{ bookId: 1, title: 'PDF Book' }],
  bookmarks: []
}

describe('buildMenu — book', () => {
  it('PDF context exposes Show Thumbnails and Dual Page under View', () => {
    const tpl = buildMenu(pdfCtx, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeDefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeDefined()
  })

  it('EPUB hides PDF-only items', () => {
    const tpl = buildMenu({ ...pdfCtx, format: 'epub' }, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Show TOC'])).toBeDefined()
  })

  it('MOBI hides PDF-only items', () => {
    const tpl = buildMenu({ ...pdfCtx, format: 'mobi' }, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeUndefined()
  })

  it('DJVU hides PDF-only items', () => {
    const tpl = buildMenu({ ...pdfCtx, format: 'djvu' }, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeUndefined()
  })

  it('Show TOC reflects tocOpen as checked', () => {
    const open = buildMenu({ ...pdfCtx, tocOpen: true }, vi.fn())
    const closed = buildMenu({ ...pdfCtx, tocOpen: false }, vi.fn())
    expect(findItem(open, ['View', 'Show TOC'])?.checked).toBe(true)
    expect(findItem(closed, ['View', 'Show TOC'])?.checked).toBe(false)
  })

  it('Read Aloud label flips when isReading', () => {
    const idle = buildMenu(pdfCtx, vi.fn())
    const playing = buildMenu({ ...pdfCtx, isReading: true }, vi.fn())
    expect(findItem(idle, ['Reader', 'Read Aloud'])).toBeDefined()
    expect(findItem(playing, ['Reader', 'Stop Read Aloud'])).toBeDefined()
  })

  it('Bookmarks > Add Bookmark dispatches addBookmark', () => {
    const dispatch = vi.fn()
    const tpl = buildMenu(pdfCtx, dispatch)
    const item = findItem(tpl, ['Bookmarks', 'Add Bookmark'])
    item!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'addBookmark' })
  })

  it('Open Recent submenu caps at 10', () => {
    const many = Array.from({ length: 25 }, (_, i) => ({ bookId: i, title: `B${i}` }))
    const tpl = buildMenu({ ...pdfCtx, recentBooks: many }, vi.fn())
    const recent = findItem(tpl, ['File', 'Open Recent'])
    expect((recent!.submenu as MenuItemConstructorOptions[]).length).toBe(10)
  })
})
```

Add this import to the top of the test file if not present:
```ts
import type { MenuItemConstructorOptions } from 'electron'
```

- [ ] **Step 2: Run the tests**

```bash
pnpm test src/main/menu/menuBuilder.test.ts
```
Expected: PASS (Task 3 already implemented the book menu).

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/menu/menuBuilder.test.ts
git commit -m "test(menu): book menu format gating + checkable + recent cap"
```

---

## Task 5: Window identity preload exposure

**Files:**
- Modify: `apps/rishi-electron/src/preload/index.ts` (add `windowIdentity`, `onMenuCommand`, `setMenuContext`)
- Modify: `apps/rishi-electron/src/preload/index.d.ts` (declare types)
- Create: `apps/rishi-electron/src/preload/windowIdentity.ts` (pure parser)
- Test: `apps/rishi-electron/src/preload/windowIdentity.test.ts`

- [ ] **Step 1: Write the failing test for the pure parser**

```ts
// src/preload/windowIdentity.test.ts
import { describe, it, expect } from 'vitest'
import { parseWindowIdentity } from './windowIdentity'

describe('parseWindowIdentity', () => {
  it('returns library when no flag present', () => {
    expect(parseWindowIdentity([])).toEqual({ kind: 'library' })
    expect(parseWindowIdentity(['--user-data-dir=/tmp'])).toEqual({ kind: 'library' })
  })

  it('returns library when --window-identity=library', () => {
    expect(parseWindowIdentity(['--window-identity=library'])).toEqual({ kind: 'library' })
  })

  it('returns book with bookId from --window-identity=book:42', () => {
    expect(parseWindowIdentity(['--window-identity=book:42'])).toEqual({ kind: 'book', bookId: 42 })
  })

  it('falls back to library on malformed flag', () => {
    expect(parseWindowIdentity(['--window-identity=book:abc'])).toEqual({ kind: 'library' })
    expect(parseWindowIdentity(['--window-identity=garbage'])).toEqual({ kind: 'library' })
  })
})
```

- [ ] **Step 2: Run the test**

```bash
pnpm test src/preload/windowIdentity.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Write implementation**

```ts
// src/preload/windowIdentity.ts
export type WindowIdentity =
  | { kind: 'library' }
  | { kind: 'book'; bookId: number }

const FLAG = '--window-identity='

export function parseWindowIdentity(argv: readonly string[]): WindowIdentity {
  for (const arg of argv) {
    if (!arg.startsWith(FLAG)) continue
    const value = arg.slice(FLAG.length)
    if (value === 'library') return { kind: 'library' }
    if (value.startsWith('book:')) {
      const n = Number(value.slice('book:'.length))
      if (Number.isInteger(n) && n > 0) return { kind: 'book', bookId: n }
    }
  }
  return { kind: 'library' }
}
```

- [ ] **Step 4: Run the test**

```bash
pnpm test src/preload/windowIdentity.test.ts
```
Expected: PASS.

- [ ] **Step 5: Wire into preload**

Add to `src/preload/index.ts` (near other API additions):

```ts
import { parseWindowIdentity, type WindowIdentity } from './windowIdentity'
import { ipcRenderer } from 'electron'

const windowIdentity: WindowIdentity = parseWindowIdentity(process.argv)

const menuApi = {
  windowIdentity,
  onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => {
    const handler = (_e: unknown, payload: { command: string; arg?: unknown }) => cb(payload)
    ipcRenderer.on('menu:command', handler)
    return () => ipcRenderer.removeListener('menu:command', handler)
  },
  setMenuContext: (partial: Record<string, unknown>) => {
    ipcRenderer.send('menu:setContext', partial)
  },
  openBook: (bookId: number) => ipcRenderer.invoke('window:openBook', { bookId }),
  closeBook: (bookId: number) => ipcRenderer.invoke('window:closeBook', { bookId }),
  focusLibrary: () => ipcRenderer.invoke('window:focusLibrary'),
  listOpenBooks: () => ipcRenderer.invoke('window:list')
}
```

Add `...menuApi` to the existing `electron` object exposed via `contextBridge.exposeInMainWorld('electron', { ... })`. If the existing exposure already spreads an object, add `...menuApi`. If it's exposing an `electronAPI` namespace, attach `menuApi.windowIdentity` and the rest as siblings.

Update `src/preload/index.d.ts`:

```ts
// add to the electron API interface declaration
windowIdentity: { kind: 'library' } | { kind: 'book'; bookId: number }
onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => () => void
setMenuContext: (partial: Record<string, unknown>) => void
openBook: (bookId: number) => Promise<void>
closeBook: (bookId: number) => Promise<void>
focusLibrary: () => Promise<void>
listOpenBooks: () => Promise<Array<{ bookId: number; title: string }>>
```

- [ ] **Step 6: Run typecheck**

```bash
pnpm run typecheck:node
```
Expected: no new errors in `src/preload/` or `src/main/`. (Pre-existing errors in `src/main/ipc/books.ts`, `src/main/ipc/chunks.ts`, `src/main/vectordb/embeddings.ts` are unrelated and may remain.)

- [ ] **Step 7: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/preload/windowIdentity.ts apps/rishi-electron/src/preload/windowIdentity.test.ts apps/rishi-electron/src/preload/index.ts apps/rishi-electron/src/preload/index.d.ts
git commit -m "feat(preload): expose windowIdentity + menu/window API"
```

---

## Task 6: WindowManager — library singleton

**Files:**
- Create: `apps/rishi-electron/src/main/windows/windowManager.ts`
- Test: `apps/rishi-electron/src/main/windows/windowManager.test.ts`

`BrowserWindow` is hard to instantiate in vitest. The manager takes a factory function so tests can pass a fake. The factory signature is the same the real code uses: `(opts: { kind: 'library' } | { kind: 'book'; bookId: number }) => FakeWindow | BrowserWindow`.

- [ ] **Step 1: Write the failing test**

```ts
// src/main/windows/windowManager.test.ts
import { describe, it, expect, vi } from 'vitest'
import { WindowManager, type WindowFactory, type ManagedWindow } from './windowManager'

function makeFakeWindow(): ManagedWindow {
  const listeners: Array<() => void> = []
  return {
    focus: vi.fn(),
    close: vi.fn(() => listeners.forEach((l) => l())),
    isDestroyed: vi.fn(() => false),
    on: vi.fn((event: string, cb: () => void) => { if (event === 'closed') listeners.push(cb) }),
    webContents: { send: vi.fn() }
  } as unknown as ManagedWindow
}

describe('WindowManager', () => {
  it('openLibrary creates a window the first time', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    const w = wm.openLibrary()
    expect(factory).toHaveBeenCalledTimes(1)
    expect(w).toBeDefined()
  })

  it('openLibrary returns the existing window on second call', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    const a = wm.openLibrary()
    const b = wm.openLibrary()
    expect(a).toBe(b)
    expect(factory).toHaveBeenCalledTimes(1)
    expect((a as { focus: ReturnType<typeof vi.fn> }).focus).toHaveBeenCalled()
  })

  it('openBook creates a new window for unknown bookId', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const w = wm.openBook(7)
    expect(factory).toHaveBeenCalledTimes(2)
    expect(w).toBeDefined()
  })

  it('openBook returns existing window for known bookId', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const a = wm.openBook(7)
    const b = wm.openBook(7)
    expect(a).toBe(b)
    expect(factory).toHaveBeenCalledTimes(2)
  })

  it('closeBook removes the window from the map', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    wm.openBook(7)
    expect(wm.hasBook(7)).toBe(true)
    wm.closeBook(7)
    expect(wm.hasBook(7)).toBe(false)
  })

  it('removes book from map when window emits closed', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const w = wm.openBook(7) as unknown as ManagedWindow
    expect(wm.hasBook(7)).toBe(true)
    w.close()
    expect(wm.hasBook(7)).toBe(false)
  })
})
```

- [ ] **Step 2: Run the test**

```bash
pnpm test src/main/windows/windowManager.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
// src/main/windows/windowManager.ts
import type { BrowserWindow } from 'electron'

export type WindowIdentity =
  | { kind: 'library' }
  | { kind: 'book'; bookId: number }

export interface ManagedWindow {
  focus(): void
  close(): void
  isDestroyed(): boolean
  on(event: 'closed', cb: () => void): unknown
  webContents: { send(channel: string, payload: unknown): void }
}

export type WindowFactory = (identity: WindowIdentity) => ManagedWindow | BrowserWindow

export class WindowManager {
  private library: ManagedWindow | null = null
  private books = new Map<number, ManagedWindow>()

  constructor(private factory: WindowFactory) {}

  openLibrary(): ManagedWindow {
    if (this.library && !this.library.isDestroyed()) {
      this.library.focus()
      return this.library
    }
    const w = this.factory({ kind: 'library' }) as ManagedWindow
    w.on('closed', () => { this.library = null })
    this.library = w
    return w
  }

  openBook(bookId: number): ManagedWindow {
    const existing = this.books.get(bookId)
    if (existing && !existing.isDestroyed()) {
      existing.focus()
      return existing
    }
    const w = this.factory({ kind: 'book', bookId }) as ManagedWindow
    w.on('closed', () => { this.books.delete(bookId) })
    this.books.set(bookId, w)
    return w
  }

  closeBook(bookId: number): void {
    const w = this.books.get(bookId)
    if (w && !w.isDestroyed()) w.close()
    this.books.delete(bookId)
  }

  hasBook(bookId: number): boolean {
    return this.books.has(bookId)
  }

  getLibrary(): ManagedWindow | null {
    return this.library
  }

  getBook(bookId: number): ManagedWindow | null {
    return this.books.get(bookId) ?? null
  }

  allWindows(): ManagedWindow[] {
    const list: ManagedWindow[] = []
    if (this.library) list.push(this.library)
    for (const w of this.books.values()) list.push(w)
    return list
  }
}
```

- [ ] **Step 4: Run the test**

```bash
pnpm test src/main/windows/windowManager.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/windows/windowManager.ts apps/rishi-electron/src/main/windows/windowManager.test.ts
git commit -m "feat(windows): WindowManager owns library + book windows"
```

---

## Task 7: Real `BrowserWindow` factory

**Files:**
- Create: `apps/rishi-electron/src/main/windows/createBrowserWindow.ts`
- (No unit test — this wraps Electron's `BrowserWindow` constructor; covered by Phase-1 integration tests.)

- [ ] **Step 1: Write the factory**

```ts
// src/main/windows/createBrowserWindow.ts
import { BrowserWindow, app } from 'electron'
import path from 'node:path'
import { is } from '@electron-toolkit/utils'
import type { WindowIdentity } from './windowManager'

export interface FactoryDeps {
  loadUrl: string                       // dev: ELECTRON_RENDERER_URL; prod: http://localhost:<port>
  preloadPath: string                   // path.join(__dirname, '../preload/index.js')
}

export function makeBrowserWindowFactory(deps: FactoryDeps) {
  return (identity: WindowIdentity): BrowserWindow => {
    const win = new BrowserWindow({
      width: identity.kind === 'library' ? 1024 : 1100,
      height: identity.kind === 'library' ? 770 : 900,
      minWidth: 800,
      minHeight: 600,
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 15, y: 10 },
      show: false,
      webPreferences: {
        preload: deps.preloadPath,
        sandbox: false,
        contextIsolation: true,
        nodeIntegration: false,
        webSecurity: false,
        additionalArguments: [`--window-identity=${identityFlag(identity)}`]
      }
    })
    win.on('ready-to-show', () => win.show())

    const hash = identity.kind === 'book' ? `#/books/${identity.bookId}` : '#/'
    win.loadURL(`${deps.loadUrl}${hash}`)
    return win
  }
}

function identityFlag(i: WindowIdentity): string {
  return i.kind === 'book' ? `book:${i.bookId}` : 'library'
}

export const __forTest = { identityFlag }
```

- [ ] **Step 2: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/windows/createBrowserWindow.ts
git commit -m "feat(windows): real BrowserWindow factory with identity flag"
```

---

## Task 8: Menu command dispatch (main side)

**Files:**
- Create: `apps/rishi-electron/src/main/menu/installMenu.ts`
- Test: `apps/rishi-electron/src/main/menu/installMenu.test.ts`

This module owns:
1. Holding the current `MenuContext` per window.
2. Re-installing the application menu whenever the focused window's identity-kind or context hash changes.
3. Dispatching menu clicks via `webContents.send('menu:command', payload)` to the focused window.

- [ ] **Step 1: Write the failing test**

```ts
// src/main/menu/installMenu.test.ts
import { describe, it, expect, vi } from 'vitest'
import { MenuInstaller, hashContext } from './installMenu'
import type { MenuContext } from './commands'

const libraryCtx: MenuContext = { kind: 'library', theme: 'light', recentBooks: [], openBookTitles: [] }

describe('MenuInstaller', () => {
  it('builds the menu on first install', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    expect(setMenu).toHaveBeenCalledTimes(1)
  })

  it('skips rebuild when context hash unchanged', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    inst.setContext({ ...libraryCtx })
    expect(setMenu).toHaveBeenCalledTimes(1)
  })

  it('rebuilds when identity kind changes', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    inst.setContext({
      kind: 'book', bookId: 1, format: 'pdf', title: 'X',
      tocOpen: false, thumbsOpen: false, dualPage: false, isReading: false,
      theme: 'light', recentBooks: [], openBookTitles: [], bookmarks: []
    })
    expect(setMenu).toHaveBeenCalledTimes(2)
  })

  it('forwards menu click as { command, arg } via send', () => {
    const send = vi.fn()
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, send)
    inst.setContext(libraryCtx)
    // pull template, find Import Book, click it
    const tpl = inst.currentTemplate()
    expect(tpl).toBeDefined()
    const file = tpl!.find((m) => m.label === 'File')!
    const sub = file.submenu as Array<{ label?: string; click?: () => void }>
    const importItem = sub.find((m) => m.label === 'Import Book…')!
    importItem.click!()
    expect(send).toHaveBeenCalledWith({ command: 'importBook' })
  })

  it('hashContext changes when tocOpen flips', () => {
    const a: MenuContext = {
      kind: 'book', bookId: 1, format: 'pdf', title: 'X',
      tocOpen: false, thumbsOpen: false, dualPage: false, isReading: false,
      theme: 'light', recentBooks: [], openBookTitles: [], bookmarks: []
    }
    const b = { ...a, tocOpen: true }
    expect(hashContext(a)).not.toBe(hashContext(b))
  })
})
```

- [ ] **Step 2: Run the test**

```bash
pnpm test src/main/menu/installMenu.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
// src/main/menu/installMenu.ts
import type { MenuItemConstructorOptions } from 'electron'
import { buildMenu } from './menuBuilder'
import type { MenuCommand, MenuContext } from './commands'

export type SetApplicationMenu = (template: MenuItemConstructorOptions[]) => void
export type SendToFocused = (command: MenuCommand) => void

export class MenuInstaller {
  private lastHash: string | null = null
  private lastTemplate: MenuItemConstructorOptions[] | null = null

  constructor(private setMenu: SetApplicationMenu, private send: SendToFocused) {}

  setContext(ctx: MenuContext): void {
    const h = hashContext(ctx)
    if (h === this.lastHash) return
    this.lastHash = h
    const tpl = buildMenu(ctx, (c) => this.send(c))
    this.lastTemplate = tpl
    this.setMenu(tpl)
  }

  currentTemplate(): MenuItemConstructorOptions[] | null {
    return this.lastTemplate
  }
}

export function hashContext(ctx: MenuContext): string {
  return JSON.stringify(ctx)
}
```

- [ ] **Step 4: Run the test**

```bash
pnpm test src/main/menu/installMenu.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/menu/installMenu.ts apps/rishi-electron/src/main/menu/installMenu.test.ts
git commit -m "feat(menu): MenuInstaller with hash-based rebuild gating"
```

---

## Task 9: Wire WindowManager + MenuInstaller into `src/main/index.ts`

**Files:**
- Modify: `apps/rishi-electron/src/main/index.ts`

After this task: the library window is created via the window manager, the native menu is installed, menu commands forward to the focused window. `mainWindow` global is replaced by `windowManager.getLibrary()`.

- [ ] **Step 1: Read `src/main/index.ts` start-to-end**

(No code change yet — re-read to ground yourself in the existing flow: `createWindow`, single-instance lock, `app.whenReady`, `open-file` handling.)

- [ ] **Step 2: Add the wiring**

Add near the top of `src/main/index.ts` (after existing imports):

```ts
import { BrowserWindow, Menu, ipcMain } from 'electron'
import { WindowManager } from './windows/windowManager'
import { makeBrowserWindowFactory } from './windows/createBrowserWindow'
import { MenuInstaller } from './menu/installMenu'
import type { MenuContext, MenuCommand } from './menu/commands'

let windowManager: WindowManager | null = null
let menuInstaller: MenuInstaller | null = null
// Per-window MenuContext, keyed by webContents.id, so context for a focus
// switch is whatever that window last reported.
const windowContexts = new Map<number, MenuContext>()

function bootstrapMenuAndWindows(loadUrl: string, preloadPath: string): void {
  const factory = makeBrowserWindowFactory({ loadUrl, preloadPath })
  windowManager = new WindowManager(factory)
  menuInstaller = new MenuInstaller(
    (template) => Menu.setApplicationMenu(Menu.buildFromTemplate(template)),
    (cmd) => {
      const focused = BrowserWindow.getFocusedWindow()
      if (focused) focused.webContents.send('menu:command', cmd)
    }
  )

  app.on('browser-window-focus', (_e, win) => {
    const ctx = windowContexts.get(win.webContents.id) ?? defaultLibraryContext()
    menuInstaller!.setContext(ctx)
  })

  ipcMain.on('menu:setContext', (event, partial: Partial<MenuContext>) => {
    const id = event.sender.id
    const merged = mergeContext(windowContexts.get(id), partial)
    windowContexts.set(id, merged)
    if (BrowserWindow.fromWebContents(event.sender) === BrowserWindow.getFocusedWindow()) {
      menuInstaller!.setContext(merged)
    }
  })

  ipcMain.handle('window:openBook', async (_e, { bookId }: { bookId: number }) => {
    const win = windowManager!.openBook(bookId)
    // Pre-seed the book window's menu context from the DB (better-sqlite3
    // sync read via the existing books repo — see src/main/repos/booksRepo.ts
    // or its equivalent). This way the menu shows the right format-specific
    // items the first time the window focuses, before the renderer's
    // setMenuContext publish lands.
    const row = readBookByIdSync(bookId) // implement in repo if not present
    if (row) {
      windowContexts.set((win as { webContents: { id: number } }).webContents.id, {
        kind: 'book',
        bookId,
        format: row.kind as 'pdf' | 'epub' | 'mobi' | 'djvu',
        title: row.title,
        tocOpen: false, thumbsOpen: false, dualPage: false, isReading: false,
        theme: 'light',
        recentBooks: [],
        openBookTitles: [],
        bookmarks: []
      })
    }
  })
  ipcMain.handle('window:closeBook', async (_e, { bookId }: { bookId: number }) => {
    windowManager!.closeBook(bookId)
  })
  ipcMain.handle('window:focusLibrary', async () => {
    windowManager!.openLibrary()
  })
  ipcMain.handle('window:list', async () => {
    // Phase 4 will populate titles; for now return empty list.
    return []
  })
}

function defaultLibraryContext(): MenuContext {
  return { kind: 'library', theme: 'light', recentBooks: [], openBookTitles: [] }
}

function mergeContext(prev: MenuContext | undefined, partial: Partial<MenuContext>): MenuContext {
  if (!prev) return { ...defaultLibraryContext(), ...(partial as object) } as MenuContext
  return { ...prev, ...(partial as object) } as MenuContext
}
```

Inside `app.whenReady().then(...)`, replace the existing `createWindow()` invocation:

```ts
// Compute loadUrl exactly as the old createWindow did.
const preloadPath = join(__dirname, '../preload/index.js')
let loadUrl: string
if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
  loadUrl = process.env['ELECTRON_RENDERER_URL'] as string
} else {
  const rendererRoot = join(__dirname, '../renderer')
  loadUrl = await startRendererServer(rendererRoot)
}

bootstrapMenuAndWindows(loadUrl, preloadPath)
windowManager!.openLibrary()
menuInstaller!.setContext(defaultLibraryContext())
```

Remove the old `let mainWindow: BrowserWindow | null = null` and the body of `createWindow`. Any code that still references `mainWindow` (open-file handling, did-finish-load, debug instrumentation) should be migrated to `windowManager.getLibrary()`.

- [ ] **Step 3: Run typecheck**

```bash
pnpm run typecheck:node
```
Expected: pre-existing errors only.

- [ ] **Step 4: Build the app**

```bash
pnpm run build
```
Expected: success.

- [ ] **Step 5: Smoke-launch (manual)**

```bash
pnpm run start
```
Expect: app launches; library window appears; on macOS the system menu bar shows Rishi/File/Edit/View/Window/Help. Close.

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/index.ts
git commit -m "feat(main): install native menu + window manager on launch"
```

---

## Task 10: `useMenuCommands` renderer hook

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.ts`
- Test: `apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/routes/__root.tsx` (mount the hook)

- [ ] **Step 1: Write the failing test**

```ts
// src/renderer/src/hooks/useMenuCommands.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useMenuCommands } from './useMenuCommands'

type Listener = (c: { command: string; arg?: unknown }) => void
let listener: Listener | null = null

beforeEach(() => {
  listener = null
  ;(globalThis as unknown as { window: { electron: object } }).window.electron = {
    onMenuCommand: (cb: Listener) => { listener = cb; return () => { listener = null } },
    windowIdentity: { kind: 'library' }
  } as object
})

describe('useMenuCommands', () => {
  it('dispatches importBook to handler', () => {
    const handlers = { importBook: vi.fn(), toggleTheme: vi.fn() }
    renderHook(() => useMenuCommands(handlers))
    listener!({ command: 'importBook' })
    expect(handlers.importBook).toHaveBeenCalled()
  })

  it('ignores commands with no registered handler', () => {
    const handlers = { importBook: vi.fn() }
    renderHook(() => useMenuCommands(handlers))
    expect(() => listener!({ command: 'doesNotExist' })).not.toThrow()
  })

  it('unsubscribes on unmount', () => {
    const dispose = vi.fn()
    ;(globalThis as unknown as { window: { electron: object } }).window.electron = {
      onMenuCommand: () => dispose,
      windowIdentity: { kind: 'library' }
    } as object
    const { unmount } = renderHook(() => useMenuCommands({}))
    unmount()
    expect(dispose).toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run the test**

```bash
pnpm test src/renderer/src/hooks/useMenuCommands.test.ts
```
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
// src/renderer/src/hooks/useMenuCommands.ts
import { useEffect } from 'react'

export type MenuCommandHandlers = Partial<Record<string, (arg?: unknown) => void>>

export function useMenuCommands(handlers: MenuCommandHandlers): void {
  useEffect(() => {
    const e = (window as unknown as { electron: { onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => () => void } }).electron
    if (!e?.onMenuCommand) return
    const dispose = e.onMenuCommand(({ command, arg }) => {
      const h = handlers[command]
      if (h) h(arg)
    })
    return dispose
  }, [handlers])
}
```

- [ ] **Step 4: Run the test**

```bash
pnpm test src/renderer/src/hooks/useMenuCommands.test.ts
```
Expected: PASS.

- [ ] **Step 5: Mount the hook in `__root.tsx`**

Find `src/renderer/src/routes/__root.tsx` and inside the root component add:

```tsx
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { useThemeStore } from '@/stores/themeStore'   // adjust to actual import; replace with current theme hook
import { useNavigate } from '@tanstack/react-router'

// inside the component:
const navigate = useNavigate()
const toggleTheme = useThemeStore((s) => s.toggle)   // adjust to existing API

useMenuCommands({
  toggleTheme: () => toggleTheme(),
  importBook: () => navigate({ to: '/', search: { import: 1 } }),  // existing library handles ?import=1; adjust
  focusLibrary: () => navigate({ to: '/' })
})
```

If the theme store does not have a `toggle` action, add `toggleTheme` inline by reading the current theme and setting the opposite.

- [ ] **Step 6: Run web typecheck**

```bash
pnpm run typecheck:web
```
Expected: pre-existing errors only.

- [ ] **Step 7: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.ts apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.test.ts apps/rishi-electron/src/renderer/src/routes/__root.tsx
git commit -m "feat(renderer): dispatch menu commands via useMenuCommands hook"
```

---

## Task 11: Reader commands wired through pdfStore + playerStore

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx` (add useMenuCommands wiring for reader actions)

These commands must apply to the currently-rendered reader, so they're registered inside the reader component. Phase-1 still has the toolbar; that's fine, both will fire the same actions.

- [ ] **Step 1: Add menu wiring inside `PdfView`**

Inside `PdfView` (above the `return` statement), add:

```tsx
import { useMenuCommands } from '@/hooks/useMenuCommands'

// inside the component, near other hooks:
useMenuCommands({
  toggleTOC: () => setTocOpen((v) => !v),
  toggleThumbnails: () => setThumbOpen(!thumbOpen),
  toggleDualPage: () => usePdfStore.getState().toggleDualPage(),  // verify method name in pdfStore
  addBookmark: () => {
    // Existing BookmarkButton has the same action — extract its handler if needed.
    // For Phase 1, dispatch into the existing handler via a ref-callback approach
    // or call the same DB IPC the button calls.
  },
  readAloudToggle: () => usePlayerStore.getState().togglePlay(),  // verify name
  openChat: () => setChatPanelOpen((v) => !v),
  voiceChat: () => {
    // Trigger the same handler VoiceChatLauncher uses on click.
  }
})
```

For any action where the existing component encapsulates the handler internally (e.g., BookmarkButton owns its add-bookmark click), refactor that handler out into a free function in the same file or in a colocated `*.actions.ts`, then call it from both the button and the menu wiring. **No duplicated logic.**

- [ ] **Step 2: Repeat for `EpubView.tsx`, `MobiView.tsx`, `DjvuView.tsx`**

Register only the commands that apply to that format (skip `toggleThumbnails`, `toggleDualPage` for non-PDF formats).

- [ ] **Step 3: Run typecheck + manual smoke**

```bash
pnpm run typecheck:web
pnpm run build
pnpm run start
```
Open a PDF; press ⌘T → TOC opens; press ⌘D → bookmark added. Close.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx
git commit -m "feat(reader): wire menu commands into reader components"
```

---

## Task 12: Playwright helper for reading the application menu

**Files:**
- Modify: `apps/rishi-electron/e2e/helpers/electron-app.ts`

- [ ] **Step 1: Append helpers**

```ts
// e2e/helpers/electron-app.ts (append)
import type { ElectronApplication } from '@playwright/test'

export interface MenuShape {
  label?: string
  role?: string
  accelerator?: string
  type?: string
  checked?: boolean
  visible?: boolean
  enabled?: boolean
  submenu?: MenuShape[]
}

export async function getApplicationMenu(app: ElectronApplication): Promise<MenuShape[]> {
  return await app.evaluate(({ Menu }) => {
    const m = Menu.getApplicationMenu()
    if (!m) return []
    const walk = (items: Electron.MenuItem[]): unknown[] =>
      items.map((i) => ({
        label: i.label || undefined,
        role: (i as unknown as { role?: string }).role,
        accelerator: (i as unknown as { accelerator?: string }).accelerator,
        type: i.type,
        checked: i.checked,
        visible: i.visible,
        enabled: i.enabled,
        submenu: i.submenu ? walk(i.submenu.items) : undefined
      }))
    return walk(m.items)
  }) as MenuShape[]
}

export function findMenuItem(menu: MenuShape[], pathLabels: string[]): MenuShape | undefined {
  let cursor: MenuShape[] | undefined = menu
  let found: MenuShape | undefined
  for (const label of pathLabels) {
    if (!cursor) return undefined
    found = cursor.find((m) => m.label === label)
    if (!found) return undefined
    cursor = found.submenu
  }
  return found
}

export async function clickMenuItem(app: ElectronApplication, pathLabels: string[]): Promise<boolean> {
  return await app.evaluate(({ Menu }, labels) => {
    const m = Menu.getApplicationMenu()
    if (!m) return false
    const find = (items: Electron.MenuItem[], rest: string[]): Electron.MenuItem | null => {
      if (rest.length === 0) return null
      const [head, ...tail] = rest
      const hit = items.find((i) => i.label === head)
      if (!hit) return null
      if (tail.length === 0) return hit
      if (!hit.submenu) return null
      return find(hit.submenu.items, tail)
    }
    const item = find(m.items, labels)
    if (!item) return false
    item.click()
    return true
  }, pathLabels) as boolean
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/helpers/electron-app.ts
git commit -m "test(e2e): helpers for reading + clicking application menu"
```

---

## Task 13: Playwright spec — library menu shape

**Files:**
- Create: `apps/rishi-electron/e2e/menu-library.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// e2e/menu-library.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, getApplicationMenu, findMenuItem } from './helpers/electron-app'

test('library window menu has File/Edit/View/Window/Help but no Bookmarks/Reader', async () => {
  const launched = await launchApp()
  try {
    const menu = await getApplicationMenu(launched.app)
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View', 'Window', 'Help']))
    expect(labels).not.toContain('Bookmarks')
    expect(labels).not.toContain('Reader')

    expect(findMenuItem(menu, ['File', 'Import Book…'])).toBeDefined()
    expect(findMenuItem(menu, ['Window', 'Library'])?.accelerator).toMatch(/Cmd|Ctrl/)
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 2: Build + run the test**

```bash
pnpm run build
pnpm exec playwright test e2e/menu-library.spec.ts
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/menu-library.spec.ts
git commit -m "test(e2e): assert library window menu shape"
```

---

## Task 14: Playwright spec — menu command fires renderer action

**Files:**
- Create: `apps/rishi-electron/e2e/menu-commands.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// e2e/menu-commands.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, clickMenuItem, PDF_FIXTURE } from './helpers/electron-app'

test('View > Switch to Dark Mode toggles theme in renderer', async () => {
  const launched = await launchApp()
  try {
    const themeBefore = await launched.page.evaluate(() =>
      document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    )
    const label = themeBefore === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'
    const clicked = await clickMenuItem(launched.app, ['View', label])
    expect(clicked).toBe(true)
    await launched.page.waitForTimeout(200)
    const themeAfter = await launched.page.evaluate(() =>
      document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    )
    expect(themeAfter).not.toBe(themeBefore)
  } finally {
    await closeApp(launched)
  }
})

test('Bookmarks > Add Bookmark adds a row in the DB when a PDF is open', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'Menu PDF' })
    await openBook(launched.page, book.id)
    await launched.page.waitForTimeout(1500)
    const before = await launched.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const list = (await e.listBookmarksForBook(id)) as unknown[]
      return list.length
    }, book.id)
    const clicked = await clickMenuItem(launched.app, ['Bookmarks', 'Add Bookmark'])
    expect(clicked).toBe(true)
    await launched.page.waitForTimeout(500)
    const after = await launched.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const list = (await e.listBookmarksForBook(id)) as unknown[]
      return list.length
    }, book.id)
    expect(after).toBe(before + 1)
  } finally {
    await closeApp(launched)
  }
})
```

> Note: the exact IPC method name `listBookmarksForBook` may not match — substitute the real bookmark-list IPC for the project. Confirm via `grep -n 'bookmarks' apps/rishi-electron/src/preload/index.ts`. If absent, add a minimal IPC helper in the same task, but only if needed by this test.

- [ ] **Step 2: Run**

```bash
pnpm exec playwright test e2e/menu-commands.spec.ts
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/menu-commands.spec.ts
git commit -m "test(e2e): menu commands toggle theme + add bookmark"
```

---

# Phase 2 — Drop the in-window toolbar

Goal: the reader toolbar component and its mounts are removed; menu items are the sole entry point.

---

## Task 15: Delete `ReaderToolbar` and its callers' mounts

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/components/reader/ReaderToolbar.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx`

- [ ] **Step 1: Search and replace**

```bash
cd apps/rishi-electron
grep -rln "ReaderToolbar" src/
```

For every file: delete the `<ReaderToolbar ...>...</ReaderToolbar>` block and the corresponding `import { ReaderToolbar }` line.

- [ ] **Step 2: Delete the file**

```bash
rm src/renderer/src/components/reader/ReaderToolbar.tsx
```

- [ ] **Step 3: Move TOC trigger to a `Sheet` controlled by tocOpen**

`ReaderToolbar` previously rendered the TOC trigger `IconButton`. The `Sheet` for TOC is already mounted inside each reader; the `setTocOpen(true)` was on the toolbar button. Now `useMenuCommands({ toggleTOC: () => setTocOpen(v => !v) })` (already added in Task 11) drives it. Same for `thumbOpen` and bookmark add.

Confirm no orphaned references:

```bash
grep -rln "ReaderToolbar\|BackButton" src/
```

Expected: zero matches except possibly comments — delete those too if they exist.

- [ ] **Step 4: Run typecheck + tests**

```bash
pnpm run typecheck:web
pnpm test
```
Expected: pre-existing errors only.

- [ ] **Step 5: Build + manual smoke**

```bash
pnpm run build && pnpm run start
```
Open a book. The top-right floating bar should be gone. Use ⌘T to open TOC.

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/renderer/src/components/reader/ apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx
git commit -m "refactor(reader): remove ReaderToolbar; menu is sole entry"
```

---

## Task 16: Delete `BackButton` and `useSetupMenu`

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/components/BackButton.tsx`
- Delete: `apps/rishi-electron/src/renderer/src/components/pdf/hooks/useSetupMenu.tsx`
- Modify: any remaining callers found by grep

- [ ] **Step 1: Find and remove callers**

```bash
cd apps/rishi-electron
grep -rln "BackButton\|useSetupMenu" src/
```

For each match, remove the import and any JSX usage. The native menu replaces both.

- [ ] **Step 2: Delete the files**

```bash
rm src/renderer/src/components/BackButton.tsx src/renderer/src/components/pdf/hooks/useSetupMenu.tsx
```

- [ ] **Step 3: Typecheck + commit**

```bash
pnpm run typecheck:web
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/renderer/src/
git commit -m "refactor(reader): remove BackButton + useSetupMenu (menu owns it)"
```

---

## Task 17: Update / delete obsolete toolbar specs

**Files:**
- Delete: `apps/rishi-electron/e2e/pdf-toolbar-sticky.spec.ts` (and any other spec asserting toolbar visibility)

- [ ] **Step 1: List specs that reference the toolbar**

```bash
grep -rln "reader-toolbar\|ReaderToolbar\|revealReaderToolbar" apps/rishi-electron/e2e/
```

For each match: if the spec is *about* the toolbar, delete it. If it just used the toolbar to reach a state (e.g., open TOC), update it to call `clickMenuItem(launched.app, ['View', 'Show TOC'])` instead.

Also delete `revealReaderToolbar` from `e2e/helpers/electron-app.ts` and any of its callers — replace those callers with `clickMenuItem(...)`.

- [ ] **Step 2: Run the e2e suite to find any regressions**

```bash
cd apps/rishi-electron
pnpm run build
pnpm exec playwright test
```

Fix any tests that broke because they relied on the toolbar.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/e2e/
git commit -m "test(e2e): drop toolbar-coupled specs; migrate to menu"
```

---

## Task 18: Playwright spec — toolbar gone

**Files:**
- Create: `apps/rishi-electron/e2e/no-toolbar.spec.ts`

- [ ] **Step 1: Write the test**

```ts
// e2e/no-toolbar.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, PDF_FIXTURE } from './helpers/electron-app'

test('reader has no in-window top toolbar after phase 2', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })
    await openBook(launched.page, book.id)
    await launched.page.waitForTimeout(1500)
    const count = await launched.page.locator('[data-tour="reader-toolbar"]').count()
    expect(count).toBe(0)
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 2: Run + commit**

```bash
pnpm exec playwright test e2e/no-toolbar.spec.ts
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/no-toolbar.spec.ts
git commit -m "test(e2e): assert reader toolbar is gone after phase 2"
```

---

# Phase 3 — Window split

Goal: library is one window, each book is its own window, with correct identity injection and menu-driven navigation.

---

## Task 19: Library row click → `openBook` IPC

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/routes/index.lazy.tsx` (or the library component)

- [ ] **Step 1: Find the row click handler**

```bash
grep -rn "navigate.*books\|to.*books/\\\$id\|/books/'.*id" src/renderer/src/routes/
```

Identify the library row's onClick. It currently calls `navigate({ to: '/books/$id', params: { id } })` or similar.

- [ ] **Step 2: Replace with `openBook`**

Replace the in-window navigation with the IPC call:

```ts
const onRowClick = (bookId: number) => {
  void (window as unknown as { electron: { openBook(id: number): Promise<void> } }).electron.openBook(bookId)
}
```

- [ ] **Step 3: Build + manual smoke**

```bash
pnpm run build && pnpm run start
```
Click a book in the library — a second window should open with the book.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/renderer/src/routes/
git commit -m "feat(library): row click opens dedicated book window"
```

---

## Task 20: Identity guard in `__root.tsx`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/routes/__root.tsx`

- [ ] **Step 1: Read identity and apply guard**

```tsx
import { useEffect } from 'react'
import { useNavigate, useLocation } from '@tanstack/react-router'

// inside the root component:
useEffect(() => {
  const e = (window as unknown as { electron: { windowIdentity: { kind: 'library' } | { kind: 'book'; bookId: number }; openBook(id: number): Promise<void> } }).electron
  const id = e?.windowIdentity
  const path = window.location.hash.replace(/^#/, '')

  if (id?.kind === 'library') {
    const m = path.match(/^\/books\/(\d+)/)
    if (m) {
      // Library window asked to render /books/N — spawn a book window, return home.
      void e.openBook(Number(m[1]))
      navigate({ to: '/' })
    }
  } else if (id?.kind === 'book') {
    if (!path.startsWith('/books/')) {
      navigate({ to: '/books/$id', params: { id: String(id.bookId) } })
    }
  }
}, [])
```

- [ ] **Step 2: Run typecheck + manual smoke**

```bash
pnpm run typecheck:web
pnpm run build && pnpm run start
```
Open a book — book window opens, never shows the library briefly. Close the book window, open the same book again — focuses the existing window (no duplicate).

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/renderer/src/routes/__root.tsx
git commit -m "feat(renderer): route guard enforces window identity"
```

---

## Task 21: File-association → `openBook`

**Files:**
- Modify: `apps/rishi-electron/src/main/index.ts` (replace the `open-file` and `second-instance` handlers to route through `windowManager`)

- [ ] **Step 1: Find existing handlers**

`open-file` (mac) and `second-instance` (win/linux) currently call `deliverOpenFiles` which buffers paths and sends `open-files` to the renderer once it's ready. We keep that broadcast for the library window (which still handles the import flow), but additionally, after a book row is created, we open a window for it.

The cleanest split: `deliverOpenFiles` continues to import (existing behavior); once a book row exists, the library renderer calls `window.electron.openBook(bookId)` to spawn the window. Since the existing import code already navigates to the book route, change that navigation to `openBook` (Task 19 already did this).

- [ ] **Step 2: Verify by manual smoke**

```bash
pnpm run build
open dist/mac-arm64/Rishi.app /path/to/test-book.pdf   # or `start` on Windows
```
Expected: a book window opens for the file.

- [ ] **Step 3: Commit (likely empty diff if Task 19 covered it; skip if so)**

If any wiring needed adjusting:
```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/main/index.ts
git commit -m "feat(main): file-association opens a dedicated book window"
```

---

## Task 22: Window menu lists open books

**Files:**
- Modify: `apps/rishi-electron/src/main/index.ts` (track open-book titles, broadcast on change)
- Modify: `apps/rishi-electron/src/main/windows/windowManager.ts` (expose title-change events)
- Modify: `apps/rishi-electron/src/main/menu/installMenu.ts` (already accepts openBookTitles via context)

- [ ] **Step 1: Add a `setTitle(bookId, title)` IPC**

In main: an IPC channel `window:setBookTitle` that the book renderer calls once it knows the book's title. The main process updates an internal `bookTitles: Map<number, string>` and re-installs the menu for the focused window (so its Window submenu picks up the new entry).

```ts
// inside bootstrapMenuAndWindows in src/main/index.ts
const bookTitles = new Map<number, string>()

ipcMain.on('window:setBookTitle', (event, { bookId, title }: { bookId: number; title: string }) => {
  bookTitles.set(bookId, title)
  // Refresh menu for all windows that show the Window submenu
  for (const win of BrowserWindow.getAllWindows()) {
    const id = win.webContents.id
    const ctx = windowContexts.get(id)
    if (!ctx) continue
    const updated = {
      ...ctx,
      openBookTitles: Array.from(bookTitles, ([bookId, title]) => ({ bookId, title }))
    } as MenuContext
    windowContexts.set(id, updated)
    if (BrowserWindow.fromWebContents(event.sender) === BrowserWindow.getFocusedWindow()) {
      menuInstaller!.setContext(updated)
    }
  }
})
```

- [ ] **Step 2: Renderer publishes title from each reader**

In `PdfView`, `EpubView`, `MobiView`, `DjvuView`, on mount with a known `book.title`, call:

```ts
useEffect(() => {
  const e = (window as unknown as { electron: { send(c: string, p: unknown): void } }).electron
  e?.send('window:setBookTitle', { bookId: book.id, title: book.title })
}, [book.id, book.title])
```

- [ ] **Step 3: Build + manual smoke**

Open two books. The Window menu should list both titles, with the focused book checked.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/main/ apps/rishi-electron/src/renderer/
git commit -m "feat(window): Window menu lists open books"
```

---

## Task 23: Playwright spec — window split

**Files:**
- Create: `apps/rishi-electron/e2e/window-split.spec.ts`

- [ ] **Step 1: Write the test**

```ts
// e2e/window-split.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, PDF_FIXTURE, EPUB_FIXTURE } from './helpers/electron-app'

test('opening two books results in two book windows + one library', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'A PDF' })
    const b = await importBook(launched.page, { fixturePath: EPUB_FIXTURE, kind: 'epub', title: 'B EPUB' })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(1000)
    await openBook(launched.page, b.id)
    await launched.page.waitForTimeout(1000)
    const wins = launched.app.windows()
    expect(wins.length).toBe(3)
  } finally {
    await closeApp(launched)
  }
})

test('opening the same book twice does not duplicate windows', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'A PDF' })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(800)
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(800)
    const wins = launched.app.windows()
    expect(wins.length).toBe(2) // library + a
  } finally {
    await closeApp(launched)
  }
})

test('book window windowIdentity is book; library is library', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(1000)
    const allWins = launched.app.windows()
    const identities = await Promise.all(allWins.map(async (p) => {
      return await p.evaluate(() =>
        (window as unknown as { electron: { windowIdentity: unknown } }).electron.windowIdentity
      )
    }))
    expect(identities).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: 'library' }),
        expect.objectContaining({ kind: 'book', bookId: a.id })
      ])
    )
  } finally {
    await closeApp(launched)
  }
})
```

Note: `openBook(page, id)` in the helper currently uses `window.location.hash = #/books/N` which only works inside the library window. Update the helper to call `window.electron.openBook(id)` instead:

```ts
// Update the existing helper
export async function openBook(page: Page, bookId: number): Promise<void> {
  await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { openBook(id: number): Promise<void> } }).electron
    await e.openBook(id)
  }, bookId)
}
```

- [ ] **Step 2: Run**

```bash
pnpm run build
pnpm exec playwright test e2e/window-split.spec.ts
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/window-split.spec.ts apps/rishi-electron/e2e/helpers/electron-app.ts
git commit -m "test(e2e): window split — separate windows + no duplicates"
```

---

## Task 24: Playwright spec — book window menu (PDF) vs EPUB

**Files:**
- Create: `apps/rishi-electron/e2e/menu-book-pdf.spec.ts`
- Create: `apps/rishi-electron/e2e/menu-book-epub.spec.ts`

- [ ] **Step 1: PDF book menu**

```ts
// e2e/menu-book-pdf.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, PDF_FIXTURE, getApplicationMenu, findMenuItem } from './helpers/electron-app'

test('focused PDF book window menu has Bookmarks, Reader, Show Thumbnails, Dual Page', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'PDF M' })
    await openBook(launched.page, book.id)
    await launched.page.waitForTimeout(1500)

    // Bring the focused window to the foreground in the test by clicking inside it
    const wins = launched.app.windows()
    const bookPage = wins.find((w) => w.url().includes(`/books/${book.id}`))!
    await bookPage.bringToFront()
    await launched.page.waitForTimeout(300)

    const menu = await getApplicationMenu(launched.app)
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['Bookmarks', 'Reader']))
    expect(findMenuItem(menu, ['View', 'Show Thumbnails'])).toBeDefined()
    expect(findMenuItem(menu, ['View', 'Dual Page'])).toBeDefined()
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 2: EPUB book menu**

```ts
// e2e/menu-book-epub.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, EPUB_FIXTURE, getApplicationMenu, findMenuItem } from './helpers/electron-app'

test('focused EPUB book window menu hides PDF-only items', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, { fixturePath: EPUB_FIXTURE, kind: 'epub', title: 'EPUB M' })
    await openBook(launched.page, book.id)
    await launched.page.waitForTimeout(1500)

    const wins = launched.app.windows()
    const bookPage = wins.find((w) => w.url().includes(`/books/${book.id}`))!
    await bookPage.bringToFront()
    await launched.page.waitForTimeout(300)

    const menu = await getApplicationMenu(launched.app)
    expect(findMenuItem(menu, ['View', 'Show TOC'])).toBeDefined()
    expect(findMenuItem(menu, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findMenuItem(menu, ['View', 'Dual Page'])).toBeUndefined()
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['Bookmarks', 'Reader']))
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 3: Run**

```bash
pnpm exec playwright test e2e/menu-book-pdf.spec.ts e2e/menu-book-epub.spec.ts
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/e2e/menu-book-pdf.spec.ts apps/rishi-electron/e2e/menu-book-epub.spec.ts
git commit -m "test(e2e): book window menus differ by format"
```

---

# Phase 4 — Polish

Goal: open-recent submenu, recent-bookmarks submenu populated from real data.

---

## Task 25: Recent books query + Open Recent submenu

**Files:**
- Create or extend: `apps/rishi-electron/src/main/repos/booksRepo.ts` — add `listRecentBooks(limit: number)` if absent. Inspect existing repo first.
- Modify: `apps/rishi-electron/src/main/index.ts` — before each menu rebuild for the library window, fetch recent books and include them in the context.

- [ ] **Step 1: Inspect existing books repo**

```bash
grep -rn "ORDER BY.*last\|last_read_at\|getBooks" apps/rishi-electron/src/main/ | head
```

If a recent-books query already exists, use it. Otherwise add:

```ts
// apps/rishi-electron/src/main/repos/booksRepo.ts (extend)
export function listRecentBooks(limit: number): { bookId: number; title: string }[] {
  const stmt = db.prepare(
    'SELECT id as bookId, title FROM books ORDER BY COALESCE(updated_at, created_at) DESC LIMIT ?'
  )
  return stmt.all(limit) as { bookId: number; title: string }[]
}
```

- [ ] **Step 2: Plumb into context**

In `bootstrapMenuAndWindows` (Task 9), update `defaultLibraryContext` and the focus handler to fetch fresh recents:

```ts
function defaultLibraryContext(): MenuContext {
  return {
    kind: 'library',
    theme: currentTheme(),
    recentBooks: listRecentBooks(10),
    openBookTitles: Array.from(bookTitles, ([bookId, title]) => ({ bookId, title }))
  }
}
```

- [ ] **Step 3: Wire Open Recent click**

`useMenuCommands` in `__root.tsx` already dispatches `openRecent` with `arg.bookId`. Map it to `window.electron.openBook(arg.bookId)`:

```ts
useMenuCommands({
  // ...existing
  openRecent: (arg) => {
    const id = (arg as { bookId: number } | undefined)?.bookId
    if (typeof id === 'number') void (window as unknown as { electron: { openBook(n: number): Promise<void> } }).electron.openBook(id)
  }
})
```

- [ ] **Step 4: Playwright test**

```ts
// e2e/menu-recent.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, PDF_FIXTURE, getApplicationMenu, findMenuItem, clickMenuItem } from './helpers/electron-app'

test('File > Open Recent lists imported books and opens them', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'Recent A' })
    await launched.page.waitForTimeout(500)
    const menu = await getApplicationMenu(launched.app)
    const recent = findMenuItem(menu, ['File', 'Open Recent'])
    expect(recent?.submenu?.some((m) => m.label === 'Recent A')).toBe(true)
    await clickMenuItem(launched.app, ['File', 'Open Recent', 'Recent A'])
    await launched.page.waitForTimeout(1500)
    expect(launched.app.windows().length).toBe(2)
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 5: Run + commit**

```bash
pnpm exec playwright test e2e/menu-recent.spec.ts
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/main/ apps/rishi-electron/src/renderer/src/routes/__root.tsx apps/rishi-electron/e2e/menu-recent.spec.ts
git commit -m "feat(menu): Open Recent submenu populated from books DB"
```

---

## Task 26: Bookmarks → Recent Bookmarks submenu

**Files:**
- Modify: `apps/rishi-electron/src/main/index.ts` — when a book window focuses, fetch its bookmarks via the existing repo and include them in the context.
- Modify: book renderers — send `menu:setContext` on bookmark changes (existing bookmark store likely already exposes a list; subscribe and publish).

- [ ] **Step 1: Verify the existing bookmark IPC / repo**

```bash
grep -rn "bookmark" apps/rishi-electron/src/main/ipc/ apps/rishi-electron/src/main/repos/ | head
```

Use the existing list method. Map to `BookmarkSummary { id, label, location }`.

- [ ] **Step 2: Publish bookmarks from renderer**

In each reader, on mount and after any add/delete, call:

```ts
const bookmarks = await window.electron.listBookmarksForBook(book.id)
;(window as unknown as { electron: { setMenuContext(p: object): void } }).electron.setMenuContext({
  bookmarks: bookmarks.map((b) => ({ id: b.id, label: b.label ?? `Page ${b.location}`, location: b.location }))
})
```

- [ ] **Step 3: Playwright spec**

```ts
// e2e/menu-bookmarks-submenu.spec.ts
import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, PDF_FIXTURE, clickMenuItem, getApplicationMenu, findMenuItem } from './helpers/electron-app'

test('Bookmarks > recent submenu reflects added bookmarks', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf', title: 'BM' })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(1500)

    const wins = launched.app.windows()
    const bookPage = wins.find((w) => w.url().includes(`/books/${a.id}`))!
    await bookPage.bringToFront()
    await launched.page.waitForTimeout(300)

    await clickMenuItem(launched.app, ['Bookmarks', 'Add Bookmark'])
    await launched.page.waitForTimeout(400)

    const menu = await getApplicationMenu(launched.app)
    const bookmarks = findMenuItem(menu, ['Bookmarks'])
    const labels = (bookmarks?.submenu ?? []).map((m) => m.label).filter((l): l is string => !!l)
    // At least one item beyond "Add Bookmark" and "Show All Bookmarks…" should exist
    expect(labels.some((l) => l !== 'Add Bookmark' && l !== 'Show All Bookmarks…' && !l.startsWith('('))).toBe(true)
  } finally {
    await closeApp(launched)
  }
})
```

- [ ] **Step 4: Run + commit**

```bash
pnpm exec playwright test e2e/menu-bookmarks-submenu.spec.ts
cd /Users/faridmatovu/projects/rishi-monorepo
git add -u apps/rishi-electron/src/ apps/rishi-electron/e2e/menu-bookmarks-submenu.spec.ts
git commit -m "feat(menu): Bookmarks > recent submenu reflects DB"
```

---

# End matter

## Acceptance checklist (run before merge)

- [ ] `pnpm test` (vitest) — all green, no warnings about leaked timers
- [ ] `pnpm exec playwright test` — all green on macOS
- [ ] `pnpm run typecheck` — no new errors introduced
- [ ] Manual launch on macOS — menu visible, all accelerators trigger correct action
- [ ] Manual launch on Windows (Parallels OK) — menu shows in window
- [ ] Two books open simultaneously — 3 windows total
- [ ] Closing library does not quit
- [ ] Opening a book that's already open focuses existing window, no duplicate
- [ ] File-association open creates a book window directly

## Out of scope (do not implement in this plan)

- Per-window persisted geometry.
- Drag-out tabs.
- Tear-off TOC / Thumbnails as separate windows.
- Linux global menu integration.
- Reopen previously-open book windows on next launch (defer to v2).
