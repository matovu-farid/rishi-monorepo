import { app, BrowserWindow, shell, protocol, net } from 'electron'
import { join } from 'path'
import { pathToFileURL } from 'url'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { initMainSentry } from './utils/sentry.js'
import { startRendererServer, stopRendererServer } from './utils/rendererServer.js'
import { registerAllIpcHandlers } from './ipc/index.js'
import { initDatabase } from './database/index.js'
import { initVectorDb } from './vectordb/index.js'

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

let mainWindow: BrowserWindow | null = null

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
  wc.on('did-finish-load', () =>
    console.log(`[debug:${label}] did-finish-load`, wc.getURL())
  )
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

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1024,
    height: 770,
    minWidth: 800,
    minHeight: 600,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 15, y: 10 },
    show: false,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false,
      // epub.js creates about:srcdoc iframes that need script execution.
      // webSecurity must be false so Chromium doesn't sandbox those frames.
      // Security is maintained via contextIsolation + preload + CSP.
      webSecurity: false
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow?.show()
  })

  if (mainWindow) attachDebugInstrumentation(mainWindow, 'main')

  mainWindow.webContents.setWindowOpenHandler((details) => {
    const url = details.url

    // Clerk OAuth (Google, GitHub, Apple, etc.) uses popups whose URLs route
    // through Clerk's Frontend API host, then to the OAuth provider, then
    // back. These MUST open inside the app (Apple App Store rejects sign-in
    // flows that leave for the system browser). Returning `allow` opens a
    // child BrowserWindow that shares the renderer's session.
    //
    // We match both the dev tenant (clerk.accounts.dev) and the prod
    // tenant (clerk.fidexa.org), plus the major identity providers.
    if (
      url.includes('clerk.accounts.dev') ||
      url.includes('clerk.fidexa.org') ||
      url.includes('accounts.google.com') ||
      url.includes('github.com/login') ||
      url.includes('appleid.apple.com') ||
      url.includes('facebook.com/login') ||
      url.includes('facebook.com/v') // Facebook OAuth versioned endpoints
    ) {
      return {
        action: 'allow',
        // Larger size so Google's passkey/Touch-ID prompt isn't clipped.
        overrideBrowserWindowOptions: {
          width: 600,
          height: 800,
          autoHideMenuBar: true,
          // Child windows do NOT inherit parent webPreferences (Electron 14+).
          // We deliberately avoid `sandbox: true` here: it places the renderer
          // inside Chromium's seatbelt sandbox, which on macOS prevents the
          // platform-authenticator delegate from raising a Touch ID / passkey
          // prompt during WebAuthn ceremonies. This caused Google OAuth to
          // hang at "Verifying" with no system dialog appearing.
          //
          // We DO turn web security back on (parent has it disabled for
          // epub.js srcdoc iframes, which is irrelevant here) so cross-origin
          // OAuth flows behave like a normal browser. The popup has no
          // preload and no node integration, so this is safe.
          webPreferences: {
            sandbox: false,
            contextIsolation: true,
            nodeIntegration: false,
            webSecurity: true
          }
        }
      }
    }

    // All other outbound links go to the system browser as usual.
    if (url.startsWith('http:') || url.startsWith('https:') || url.startsWith('mailto:')) {
      shell.openExternal(url)
    }
    return { action: 'deny' }
  })

  // Instrument OAuth popups (Clerk, Google, etc.) when debugging the
  // passkey/WebAuthn hang. `did-create-window` fires after Electron creates
  // the child BrowserWindow from the `setWindowOpenHandler` 'allow' return.
  mainWindow.webContents.on('did-create-window', (childWindow, { url }) => {
    console.log('[main] popup created:', url)
    attachDebugInstrumentation(childWindow, 'oauth-popup')
  })

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    // Production: serve the bundled renderer from a localhost HTTP server
    // instead of `file://`. This is required for Clerk OAuth (Clerk's
    // Frontend API rejects `file:` as a redirect URL scheme) and unblocks
    // other web platform features that Chromium gates on file:// origins.
    const rendererRoot = join(__dirname, '../renderer')
    startRendererServer(rendererRoot)
      .then((url) => mainWindow!.loadURL(url))
      .catch((err) => {
        console.error('[main] renderer server failed to start, falling back to file://', err)
        mainWindow!.loadFile(join(rendererRoot, 'index.html'))
      })
  }
}

// Single-instance lock so a second launch focuses the existing window
const gotTheLock = app.requestSingleInstanceLock()
if (!gotTheLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
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

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
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

export { mainWindow }
