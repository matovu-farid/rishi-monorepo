import { app, BrowserWindow, shell, protocol, net, ipcMain, Menu } from 'electron'
import { join, extname } from 'path'
import { pathToFileURL } from 'url'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { initMainSentry } from './utils/sentry.js'
import { startRendererServer, stopRendererServer } from './utils/rendererServer.js'
import { registerAllIpcHandlers } from './ipc/index.js'
import { initDatabase } from './database/index.js'
import { initVectorDb } from './vectordb/index.js'
import { registerAuthIpc } from './auth/index.js'
import { WindowManager } from './windows/windowManager.js'
import { makeBrowserWindowFactory } from './windows/createBrowserWindow.js'
import { MenuInstaller } from './menu/installMenu.js'
import type { MenuContext, MenuCommand, BookFormat } from './menu/commands.js'
import { getBook, listRecentBooks } from './database/queries.js'

// File types Rishi advertises in the OS "Open With" menu (see
// electron-builder.yml `fileAssociations`). The OS routes a matching file
// click to this binary; we then forward the path to the renderer for import.
const SUPPORTED_BOOK_EXTENSIONS = new Set(['.epub', '.pdf', '.mobi', '.azw3', '.djvu'])

function isSupportedBookPath(p: string): boolean {
  return SUPPORTED_BOOK_EXTENSIONS.has(extname(p).toLowerCase())
}

// Paths captured before the renderer is ready to receive them. Drained
// after `did-finish-load`, or pulled by the renderer via `files:getPending`.
const pendingOpenFiles: string[] = []
let rendererReady = false

function deliverOpenFiles(paths: string[]): void {
  const filtered = paths.filter(isSupportedBookPath)
  if (filtered.length === 0) return
  const lib = libraryWindowFromManager()
  if (rendererReady && lib && !lib.isDestroyed()) {
    lib.webContents.send('open-files', filtered)
    if (lib.isMinimized()) lib.restore()
    lib.focus()
  } else {
    pendingOpenFiles.push(...filtered)
  }
}

// macOS routes file double-clicks through this event — must be registered
// before `app.whenReady` resolves so first-launch files aren't dropped.
app.on('open-file', (event, filePath) => {
  event.preventDefault()
  deliverOpenFiles([filePath])
})

// Initialize Sentry as early as possible so startup crashes are captured.
initMainSentry()

// Set RISHI_DEBUG=1 in the launching shell to enable verbose lifecycle
// logging + auto-DevTools for the main window and OAuth popups. Used to
// diagnose the WebAuthn passkey hang. Launch the .app from a terminal:
//
//   RISHI_DEBUG=1 ./dist/mac-arm64/Rishi.app/Contents/MacOS/Rishi
//
// (macOS `open` strips env vars, so Finder/double-click won't pick this
// up — that's intentional; debug logging stays out of normal launches.)
const isDebugBuild = process.env.RISHI_DEBUG === '1'

let windowManager: WindowManager | null = null
let menuInstaller: MenuInstaller | null = null
// Per-window MenuContext, keyed by webContents.id. Persists across focus
// switches so each window's menu is rebuilt from its own last reported state.
const windowContexts = new Map<number, MenuContext>()
// Mirror of openBookTitles for the Window menu's open-books submenu.
const openBookTitles = new Map<number, string>()

/**
 * Attach verbose lifecycle + console listeners to a webContents and open
 * DevTools. Only active when the app was launched with `RISHI_DEBUG=1`.
 *
 * Used to investigate the Google passkey/WebAuthn hang in OAuth popups: we
 * want to see whether the popup hits a JS error, a network failure, a
 * `did-fail-load`, or a silent platform-authenticator timeout.
 */
function attachDebugInstrumentation(win: BrowserWindow, label: string): void {
  if (!isDebugBuild) return
  const wc = win.webContents
  // Docked right so DevTools stays attached to the window — easy to find,
  // can't get lost behind other apps the way `mode: 'detach'` can.
  wc.openDevTools({ mode: 'right' })
  wc.on('did-start-loading', () => console.log(`[debug:${label}] did-start-loading`))
  wc.on('did-finish-load', () => console.log(`[debug:${label}] did-finish-load`, wc.getURL()))
  wc.on('did-fail-load', (_e, code, desc, url) =>
    console.log(`[debug:${label}] did-fail-load`, { code, desc, url })
  )
  wc.on('did-navigate', (_e, url) => console.log(`[debug:${label}] did-navigate`, url))
  wc.on('did-navigate-in-page', (_e, url) =>
    console.log(`[debug:${label}] did-navigate-in-page`, url)
  )
  wc.on('render-process-gone', (_e, details) =>
    console.log(`[debug:${label}] render-process-gone`, details)
  )
  wc.on('unresponsive', () => console.log(`[debug:${label}] unresponsive`))
  wc.on('responsive', () => console.log(`[debug:${label}] responsive`))
  // Renderer-side console output
  wc.on('console-message', (event) => {
    const { level, message, lineNumber, sourceId } = event
    console.log(`[debug:${label}] console:${level}`, message, `(${sourceId}:${lineNumber})`)
  })
}

/**
 * Register a custom protocol `local-file://` that serves files from the
 * local filesystem. This replaces Tauri's `asset://` protocol and is the
 * Electron best practice for loading local files (PDFs, EPUBs, images)
 * into the renderer without disabling web security.
 *
 * Usage in renderer: convert a path like `/Users/x/book.pdf` to
 * `local-file:///Users/x/book.pdf`
 */
function registerLocalFileProtocol(): void {
  protocol.handle('local-file', (request) => {
    // Strip the protocol prefix to get the file path
    // local-file:///Users/x/file.pdf -> /Users/x/file.pdf
    const filePath = decodeURIComponent(request.url.replace('local-file://', ''))
    return net.fetch(pathToFileURL(filePath).href)
  })
}

function libraryWindowFromManager(): BrowserWindow | null {
  const w = windowManager?.getLibrary()
  return (w as unknown as BrowserWindow | null) ?? null
}

function attachLibraryWindowSideEffects(win: BrowserWindow): void {
  // Drain buffered open-file paths after the renderer finishes loading.
  win.webContents.once('did-finish-load', () => {
    rendererReady = true
    if (pendingOpenFiles.length > 0) {
      const paths = pendingOpenFiles.splice(0)
      win.webContents.send('open-files', paths)
    }
  })

  attachDebugInstrumentation(win, 'main')

  win.webContents.setWindowOpenHandler((details) => {
    if (
      details.url.startsWith('http:') ||
      details.url.startsWith('https:') ||
      details.url.startsWith('mailto:')
    ) {
      shell.openExternal(details.url)
    }
    return { action: 'deny' }
  })

  win.webContents.on('did-create-window', (childWindow, { url }) => {
    console.log('[main] popup created:', url)
    attachDebugInstrumentation(childWindow, 'oauth-popup')
  })
}

function bootstrapMenuAndWindows(loadUrl: string, preloadPath: string): void {
  const factory = makeBrowserWindowFactory({ loadUrl, preloadPath })
  windowManager = new WindowManager(factory)
  menuInstaller = new MenuInstaller(
    (template) => Menu.setApplicationMenu(Menu.buildFromTemplate(template)),
    (cmd: MenuCommand) => {
      const focused = BrowserWindow.getFocusedWindow()
      if (focused) focused.webContents.send('menu:command', cmd)
    }
  )

  app.on('browser-window-focus', (_e, win) => {
    const base = windowContexts.get(win.webContents.id) ?? defaultLibraryContext()
    // Always refresh dynamic lists on focus so Open Recent / Window submenus
    // reflect current DB state without waiting for a renderer ping.
    const refreshed = {
      ...base,
      recentBooks: safeListRecentBooks(),
      openBookTitles: openBookTitlesArray()
    } as MenuContext
    windowContexts.set(win.webContents.id, refreshed)
    menuInstaller!.setContext(refreshed)
  })

  // Forcible refresh of the focused window's menu — used by the library
  // renderer after a successful import so Open Recent picks up the new book
  // without waiting for a focus event. Cheap: same path as focus listener.
  // Re-installs unconditionally: in headless tests / certain platform states
  // the renderer's window may not be the OS-focused window, but the request
  // still needs to take effect.
  ipcMain.on('menu:refresh', (event) => {
    const id = event.sender.id
    const base = windowContexts.get(id) ?? defaultLibraryContext()
    const refreshed = {
      ...base,
      recentBooks: safeListRecentBooks(),
      openBookTitles: openBookTitlesArray()
    } as MenuContext
    windowContexts.set(id, refreshed)
    menuInstaller!.setContext(refreshed)
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
    const w = windowManager!.openBook(bookId) as unknown as BrowserWindow
    // Pre-seed the book window's menu context from the DB (better-sqlite3
    // sync read) so the menu shows the right format-specific items the first
    // time it focuses, before the renderer's setMenuContext lands.
    const row = getBook(bookId)
    if (row) {
      windowContexts.set(w.webContents.id, {
        kind: 'book',
        bookId,
        format: row.kind as BookFormat,
        title: row.title,
        tocOpen: false,
        thumbsOpen: false,
        dualPage: false,
        isReading: false,
        theme: 'light',
        recentBooks: safeListRecentBooks(),
        openBookTitles: openBookTitlesArray(),
        bookmarks: []
      })
      openBookTitles.set(bookId, row.title)
    }
  })

  ipcMain.handle('window:closeBook', async (_e, { bookId }: { bookId: number }) => {
    windowManager!.closeBook(bookId)
    openBookTitles.delete(bookId)
  })

  ipcMain.handle('window:focusLibrary', async () => {
    const lib = windowManager!.openLibrary() as unknown as BrowserWindow
    if (lib.isMinimized()) lib.restore()
    lib.focus()
  })

  ipcMain.handle('window:list', async () => {
    return openBookTitlesArray()
  })

  // Renderer publishes the book title once the reader has loaded so the
  // Window submenu (and the per-window menu context) shows the real title
  // instead of whatever the DB had at window-creation time. We update the
  // sender's own context, then mirror the new openBookTitles list into every
  // other live window's context so their Window submenu picks it up without
  // waiting for the next focus event.
  ipcMain.on(
    'window:setBookTitle',
    (event, { bookId, title }: { bookId: number; title: string }) => {
      openBookTitles.set(bookId, title)
      const senderId = event.sender.id
      const ctx = windowContexts.get(senderId)
      if (ctx) {
        const updated = {
          ...ctx,
          openBookTitles: openBookTitlesArray()
        } as MenuContext
        windowContexts.set(senderId, updated)
        if (BrowserWindow.fromWebContents(event.sender) === BrowserWindow.getFocusedWindow()) {
          menuInstaller!.setContext(updated)
        }
      }

      for (const w of BrowserWindow.getAllWindows()) {
        if (w.webContents.id === senderId) continue
        const otherCtx = windowContexts.get(w.webContents.id)
        if (!otherCtx) continue
        const updatedOther = {
          ...otherCtx,
          openBookTitles: openBookTitlesArray()
        } as MenuContext
        windowContexts.set(w.webContents.id, updatedOther)
        if (w === BrowserWindow.getFocusedWindow()) {
          menuInstaller!.setContext(updatedOther)
        }
      }
    }
  )
}

function openBookTitlesArray(): { bookId: number; title: string }[] {
  return Array.from(openBookTitles, ([bookId, title]) => ({ bookId, title }))
}

function safeListRecentBooks(): { bookId: number; title: string }[] {
  try {
    return listRecentBooks(10)
  } catch {
    // DB may not be ready yet (very early focus events on startup).
    return []
  }
}

function defaultLibraryContext(): MenuContext {
  return {
    kind: 'library',
    theme: 'light',
    recentBooks: safeListRecentBooks(),
    openBookTitles: openBookTitlesArray()
  }
}

function mergeContext(prev: MenuContext | undefined, partial: Partial<MenuContext>): MenuContext {
  if (!prev) return { ...defaultLibraryContext(), ...(partial as object) } as MenuContext
  return { ...prev, ...(partial as object) } as MenuContext
}

// Single-instance lock so a second launch focuses the existing window
const gotTheLock = app.requestSingleInstanceLock()
if (!gotTheLock) {
  app.quit()
} else {
  app.on('second-instance', (_event, argv) => {
    // Windows/Linux deliver "Open With" file paths via argv on a second launch.
    deliverOpenFiles(argv.slice(1).filter((a) => !a.startsWith('-')))
    const lib = libraryWindowFromManager()
    if (lib) {
      if (lib.isMinimized()) lib.restore()
      lib.focus()
    }
  })
}

app.whenReady().then(async () => {
  electronApp.setAppUserModelId('org.fidexa.rishi')

  // Register custom protocol for serving local files to renderer
  registerLocalFileProtocol()

  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  // Initialize backend services
  await initDatabase()
  initVectorDb()
  registerAllIpcHandlers()

  // Race guard: if the renderer mounts before `did-finish-load` fires, it
  // calls this to drain whatever was buffered.
  ipcMain.handle('files:getPending', () => {
    rendererReady = true
    return pendingOpenFiles.splice(0)
  })

  // First-launch file path (Windows/Linux deliver it via argv; macOS uses
  // the `open-file` event handler registered above).
  if (process.platform !== 'darwin') {
    deliverOpenFiles(process.argv.slice(1).filter((a) => !a.startsWith('-')))
  }

  const preloadPath = join(__dirname, '../preload/index.js')
  let loadUrl: string
  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    loadUrl = process.env['ELECTRON_RENDERER_URL'] as string
  } else {
    const rendererRoot = join(__dirname, '../renderer')
    try {
      loadUrl = await startRendererServer(rendererRoot)
    } catch (err) {
      console.error('[main] renderer server failed to start, falling back to file://', err)
      loadUrl = `file://${join(rendererRoot, 'index.html')}`
    }
  }

  bootstrapMenuAndWindows(loadUrl, preloadPath)
  const libWin = windowManager!.openLibrary() as unknown as BrowserWindow
  attachLibraryWindowSideEffects(libWin)
  menuInstaller!.setContext(defaultLibraryContext())

  registerAuthIpc(() => libraryWindowFromManager())

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      const w = windowManager!.openLibrary() as unknown as BrowserWindow
      attachLibraryWindowSideEffects(w)
      menuInstaller!.setContext(defaultLibraryContext())
    }
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('before-quit', () => {
  void stopRendererServer()
})
