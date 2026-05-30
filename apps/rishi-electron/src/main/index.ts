import { app, BrowserWindow, shell, protocol, net, ipcMain, Menu, dialog } from 'electron'
import { join, extname } from 'path'
import { pathToFileURL } from 'url'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { initMainSentry, captureError } from './utils/sentry.js'
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
import { handle } from '../preload/ipc-contract.js'
import {
  initSharingDeepLink,
  dispatchSecondInstanceArgv,
  drainQueuedDeepLink
} from './sharing/deepLink.js'

// File types Rishi advertises in the OS "Open With" menu (see
// electron-builder.yml `fileAssociations`). The OS routes a matching file
// click to this binary; we then forward the path to the renderer for import.
const SUPPORTED_BOOK_EXTENSIONS = new Set(['.epub', '.pdf', '.mobi', '.azw3'])

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

// Guarded accessors. Every call site that uses these is wired up *after*
// `bootstrapMenuAndWindows` runs (either inside a callback registered there,
// or in `app.whenReady` after that function returns). If we ever land here
// before initialization, throwing surfaces the bug instead of a silent
// `Cannot read properties of null` deeper in the stack.
function getWindowManager(): WindowManager {
  if (!windowManager) {
    throw new Error('windowManager accessed before bootstrapMenuAndWindows()')
  }
  return windowManager
}
function getMenuInstaller(): MenuInstaller {
  if (!menuInstaller) {
    throw new Error('menuInstaller accessed before bootstrapMenuAndWindows()')
  }
  return menuInstaller
}
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

// Crash-loop guard for `render-process-gone`. We keep a rolling list of recent
// crash timestamps per window (keyed by webContents.id); if the window crashes
// more than `CRASH_LOOP_THRESHOLD` times inside `CRASH_LOOP_WINDOW_MS` we stop
// auto-reloading and offer a "persistent crash" dialog so the user can attach
// logs / quit rather than being trapped in a reload→crash loop.
const CRASH_LOOP_WINDOW_MS = 60_000
const CRASH_LOOP_THRESHOLD = 3
const recentCrashes = new Map<number, number[]>()

function recordCrash(webContentsId: number): number {
  const now = Date.now()
  const cutoff = now - CRASH_LOOP_WINDOW_MS
  const prior = recentCrashes.get(webContentsId) ?? []
  const recent = prior.filter((t) => t >= cutoff)
  recent.push(now)
  recentCrashes.set(webContentsId, recent)
  return recent.length
}

/**
 * Handle a renderer crash on the library window. Logs the structured crash
 * details, reports to Sentry, and either auto-reloads (dev) or prompts the
 * user (prod). If the window has crashed repeatedly inside a short window we
 * stop trying to reload and surface a persistent-crash dialog instead so the
 * user can capture logs.
 *
 * Tracked via #164 (WIN-014): previously `render-process-gone` was only
 * observed in `RISHI_DEBUG=1` builds, leaving production users with a silent
 * blank window.
 */
function handleRenderProcessGone(
  win: BrowserWindow,
  label: string,
  details: Electron.RenderProcessGoneDetails
): void {
  const webContentsId = win.webContents.id
  const count = recordCrash(webContentsId)
  const payload = {
    label,
    reason: details.reason,
    exitCode: details.exitCode,
    crashCountInWindow: count,
    windowMs: CRASH_LOOP_WINDOW_MS
  }
  console.error('[main] render-process-gone', payload)
  captureError(new Error(`render-process-gone:${details.reason}`), {
    operation: 'render-process-gone',
    ...payload
  })

  // `launch-failed` cannot be recovered by `reload()` — abort fast.
  if (details.reason === 'launch-failed') {
    if (!app.isPackaged) return
    void dialog
      .showMessageBox(win, {
        type: 'error',
        buttons: ['Quit'],
        defaultId: 0,
        cancelId: 0,
        title: 'Rishi failed to start',
        message: 'The application window failed to launch.',
        detail: `Reason: ${details.reason}\nExit code: ${details.exitCode}\n\nPlease reinstall Rishi or contact support.`
      })
      .finally(() => app.quit())
    return
  }

  // Dev: HMR sometimes pushes a broken bundle. Reload silently.
  if (!app.isPackaged) {
    if (!win.isDestroyed()) win.reload()
    return
  }

  // Prod: prompt. Switch copy if the window is crash-looping so users aren't
  // stuck mashing Reload.
  const isCrashLoop = count > CRASH_LOOP_THRESHOLD
  const opts: Electron.MessageBoxOptions = isCrashLoop
    ? {
        type: 'error',
        buttons: ['Quit'],
        defaultId: 0,
        cancelId: 0,
        title: 'Rishi keeps crashing',
        message: 'The window has crashed repeatedly.',
        detail: `Reason: ${details.reason}\nExit code: ${details.exitCode}\nCrashes in the last 60s: ${count}\n\nReloading is unlikely to help. Please quit Rishi, then attach the logs from Help → Report a problem when contacting support.`
      }
    : {
        type: 'error',
        buttons: ['Reload', 'Quit'],
        defaultId: 0,
        cancelId: 1,
        title: 'Rishi window crashed',
        message: 'The window stopped responding.',
        detail: `Reason: ${details.reason}\nExit code: ${details.exitCode}\n\nReload to continue, or Quit to close Rishi.`
      }

  // Prefer attaching the modal to the crashed window; fall back to any focused
  // window if that one is already gone, and finally to a parentless dialog.
  const parent = !win.isDestroyed() ? win : BrowserWindow.getFocusedWindow()
  const dialogPromise = parent
    ? dialog.showMessageBox(parent, opts)
    : dialog.showMessageBox(opts)
  void dialogPromise
    .then((result) => {
      if (isCrashLoop) {
        app.quit()
        return
      }
      if (result.response === 0) {
        if (!win.isDestroyed()) win.reload()
      } else {
        app.quit()
      }
    })
    .catch((err: unknown) => {
      console.error('[main] render-process-gone dialog failed', err)
      app.quit()
    })
}

function attachLibraryWindowSideEffects(win: BrowserWindow): void {
  // Drain buffered open-file paths after the renderer finishes loading.
  win.webContents.once('did-finish-load', () => {
    rendererReady = true
    if (pendingOpenFiles.length > 0) {
      const paths = pendingOpenFiles.splice(0)
      win.webContents.send('open-files', paths)
    }
    // Drain any deep-link join token that arrived before the renderer was
    // ready (first-launch argv on Windows/Linux, or a second-instance event
    // received during cold start).
    const queuedToken = drainQueuedDeepLink()
    if (queuedToken) {
      win.webContents.send('sharing:deepLinkReceived', { joinToken: queuedToken })
    }
  })

  // Recover from renderer crashes — see #164. The debug build also logs this
  // via attachDebugInstrumentation, but that listener only attaches when
  // RISHI_DEBUG=1, so prod users previously had no recovery path.
  win.webContents.on('render-process-gone', (_e, details) => {
    handleRenderProcessGone(win, 'main', details)
  })

  // Snapshot the id now because `webContents.id` throws once destroyed.
  const wcId = win.webContents.id
  win.once('closed', () => {
    recentCrashes.delete(wcId)
  })

  attachDebugInstrumentation(win, 'main')

  win.webContents.setWindowOpenHandler((details) => {
    if (
      details.url.startsWith('http:') ||
      details.url.startsWith('https:') ||
      details.url.startsWith('mailto:')
    ) {
      shell.openExternal(details.url).catch((err: unknown) => {
        console.error('[main] shell.openExternal failed', err)
      })
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
    }
    windowContexts.set(win.webContents.id, refreshed)
    getMenuInstaller().setContext(refreshed)
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
    }
    windowContexts.set(id, refreshed)
    getMenuInstaller().setContext(refreshed)
  })

  ipcMain.on('menu:setContext', (event, partial: Partial<MenuContext>) => {
    const id = event.sender.id
    const merged = mergeContext(windowContexts.get(id), partial)
    windowContexts.set(id, merged)
    if (BrowserWindow.fromWebContents(event.sender) === BrowserWindow.getFocusedWindow()) {
      getMenuInstaller().setContext(merged)
    }
  })

  handle('window:openSettings', () => {
    getWindowManager().openSettings()
  })

  handle('window:openBook', (_e, bookId) => {
    const w = getWindowManager().openBook(bookId) as unknown as BrowserWindow
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

  handle('window:closeBook', (_e, bookId) => {
    getWindowManager().closeBook(bookId)
    openBookTitles.delete(bookId)
  })

  handle('window:focusLibrary', () => {
    const lib = getWindowManager().openLibrary() as unknown as BrowserWindow
    if (lib.isMinimized()) lib.restore()
    lib.focus()
  })

  handle('window:list', () => {
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
        }
        windowContexts.set(senderId, updated)
        if (BrowserWindow.fromWebContents(event.sender) === BrowserWindow.getFocusedWindow()) {
          getMenuInstaller().setContext(updated)
        }
      }

      for (const w of BrowserWindow.getAllWindows()) {
        if (w.webContents.id === senderId) continue
        const otherCtx = windowContexts.get(w.webContents.id)
        if (!otherCtx) continue
        const updatedOther = {
          ...otherCtx,
          openBookTitles: openBookTitlesArray()
        }
        windowContexts.set(w.webContents.id, updatedOther)
        if (w === BrowserWindow.getFocusedWindow()) {
          getMenuInstaller().setContext(updatedOther)
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
  if (!prev) return { ...defaultLibraryContext(), ...(partial as object) }
  return { ...prev, ...(partial as object) }
}

// Single-instance lock so a second launch focuses the existing window
const gotTheLock = app.requestSingleInstanceLock()
if (!gotTheLock) {
  app.quit()
} else {
  app.on('second-instance', (_event, argv) => {
    // Forward any `rishi://` deep-link arg from a second launch (Windows/Linux
    // route protocol clicks through argv on the second instance).
    dispatchSecondInstanceArgv(argv)
    // Windows/Linux deliver "Open With" file paths via argv on a second launch.
    deliverOpenFiles(argv.slice(1).filter((a) => !a.startsWith('-')))
    const lib = libraryWindowFromManager()
    if (lib) {
      if (lib.isMinimized()) lib.restore()
      lib.focus()
    }
  })
}

app
  .whenReady()
  .then(async () => {
    electronApp.setAppUserModelId('org.fidexa.rishi')

    // Register custom protocol for serving local files to renderer
    registerLocalFileProtocol()

    app.on('browser-window-created', (_, window) => {
      optimizer.watchWindowShortcuts(window)
    })

    // Initialize backend services
    initDatabase()
    initVectorDb()
    registerAllIpcHandlers()

    // Race guard: if the renderer mounts before `did-finish-load` fires, it
    // calls this to drain whatever was buffered.
    handle('files:getPending', () => {
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
      loadUrl = process.env['ELECTRON_RENDERER_URL']
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
    const libWin = getWindowManager().openLibrary() as unknown as BrowserWindow
    attachLibraryWindowSideEffects(libWin)
    getMenuInstaller().setContext(defaultLibraryContext())

    registerAuthIpc(() => libraryWindowFromManager())

    // Register `rishi://` protocol handler after the main window exists so
    // deep links can be routed to it (or buffered for `did-finish-load`).
    initSharingDeepLink(() => libraryWindowFromManager())

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        const w = getWindowManager().openLibrary() as unknown as BrowserWindow
        attachLibraryWindowSideEffects(w)
        getMenuInstaller().setContext(defaultLibraryContext())
      }
    })
  })
  .catch((err: unknown) => {
    console.error('[main] app initialization failed', err)
  })

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('before-quit', () => {
  void stopRendererServer()
})

// Ctrl+C in the dev-server terminal (or any external SIGTERM) only kills the
// `electron-vite dev` parent. electron-vite forwards `child.close` → parent
// `process.exit`, but does NOT forward the reverse, and Electron's main
// process ignores SIGINT/SIGTERM by default because open BrowserWindows hold
// the Chromium message loop alive — leaving an orphan dock icon on macOS.
//
// app.exit() (not app.quit()) is required because book windows preventDefault
// the close event to flush pending saves (createBrowserWindow.ts) — that
// preventDefault aborts app.quit() entirely, so the app would survive the
// signal even with a handler. Terminal SIGINT is a deliberate force-kill,
// so skipping the flush is the right tradeoff.
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) {
  process.on(signal, () => {
    console.log(`[main] received ${signal}, exiting`)
    app.exit(0)
  })
}
