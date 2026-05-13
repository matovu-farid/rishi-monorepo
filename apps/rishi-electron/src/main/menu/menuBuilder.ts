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
      {
        label: 'Import Book…',
        accelerator: ACCELERATORS.importBook,
        click: fire({ command: 'importBook' })
      },
      { label: 'Open Recent', submenu: buildRecentSubmenu(ctx.recentBooks, dispatch) },
      { type: 'separator' },
      ctx.kind === 'book'
        ? { label: 'Close Book', accelerator: ACCELERATORS.closeWindow, role: 'close' }
        : { label: 'Close Window', accelerator: ACCELERATORS.closeWindow, role: 'close' }
    ]
  }

  const editMenu: MenuItemConstructorOptions = {
    label: 'Edit',
    submenu: [
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { type: 'separator' },
      { role: 'selectAll' }
    ]
  }

  const themeLabel = ctx.theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'
  const viewSubmenu: MenuItemConstructorOptions[] = [
    {
      label: themeLabel,
      accelerator: ACCELERATORS.toggleTheme,
      click: fire({ command: 'toggleTheme' })
    },
    { type: 'separator' },
    // Built-in Electron roles handle the actual reload / devtools toggle —
    // they include sensible default accelerators (⌘R / Ctrl+R, ⌥⌘I /
    // Ctrl+Shift+I) and stay enabled only when a window is focused.
    { role: 'reload', label: 'Reload' },
    { role: 'forceReload', label: 'Force Reload' },
    { role: 'toggleDevTools', label: 'Toggle Developer Tools' }
  ]
  if (ctx.kind === 'book') {
    viewSubmenu.push(
      { type: 'separator' },
      {
        label: 'Show TOC',
        accelerator: ACCELERATORS.toggleTOC,
        type: 'checkbox',
        checked: ctx.tocOpen,
        click: fire({ command: 'toggleTOC' })
      }
    )
    if (ctx.format === 'pdf') {
      viewSubmenu.push(
        {
          label: 'Show Thumbnails',
          accelerator: ACCELERATORS.toggleThumbnails,
          type: 'checkbox',
          checked: ctx.thumbsOpen,
          click: fire({ command: 'toggleThumbnails' })
        },
        { type: 'separator' },
        {
          label: 'Dual Page',
          accelerator: ACCELERATORS.toggleDualPage,
          type: 'checkbox',
          checked: ctx.dualPage,
          click: fire({ command: 'toggleDualPage' })
        }
      )
    }
  }

  const windowSubmenu: MenuItemConstructorOptions[] = [
    { role: 'minimize' },
    { role: 'zoom' },
    { type: 'separator' },
    {
      label: 'Library',
      accelerator: ACCELERATORS.focusLibrary,
      click: fire({ command: 'focusLibrary' })
    }
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
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' }
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

function buildRecentSubmenu(
  recent: { bookId: number; title: string }[],
  dispatch: Dispatch
): MenuItemConstructorOptions[] {
  if (recent.length === 0) return [{ label: '(no recent books)', enabled: false }]
  return recent.slice(0, 10).map((r) => ({
    label: r.title,
    click: () => dispatch({ command: 'openRecent', arg: { bookId: r.bookId } })
  }))
}

function buildBookmarksMenu(
  ctx: Extract<MenuContext, { kind: 'book' }>,
  dispatch: Dispatch
): MenuItemConstructorOptions {
  const recent: MenuItemConstructorOptions[] = ctx.bookmarks.slice(0, 10).map((b) => ({
    label: b.label,
    click: () => dispatch({ command: 'jumpToBookmark', arg: { bookmarkId: b.id } })
  }))
  return {
    label: 'Bookmarks',
    submenu: [
      {
        label: 'Add Bookmark',
        accelerator: ACCELERATORS.addBookmark,
        click: () => dispatch({ command: 'addBookmark' })
      },
      { label: 'Show All Bookmarks…', click: () => dispatch({ command: 'showAllBookmarks' }) },
      { type: 'separator' },
      ...(recent.length > 0 ? recent : [{ label: '(no bookmarks yet)', enabled: false }])
    ]
  }
}

function buildReaderMenu(
  ctx: Extract<MenuContext, { kind: 'book' }>,
  dispatch: Dispatch
): MenuItemConstructorOptions {
  return {
    label: 'Reader',
    submenu: [
      {
        label: ctx.isReading ? 'Stop Read Aloud' : 'Read Aloud',
        accelerator: ACCELERATORS.readAloud,
        click: () => dispatch({ command: 'readAloudToggle' })
      },
      {
        label: 'Voice Chat',
        accelerator: ACCELERATORS.voiceChat,
        click: () => dispatch({ command: 'voiceChat' })
      },
      { type: 'separator' },
      {
        label: 'Open Chat',
        accelerator: ACCELERATORS.openChat,
        click: () => dispatch({ command: 'openChat' })
      }
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
