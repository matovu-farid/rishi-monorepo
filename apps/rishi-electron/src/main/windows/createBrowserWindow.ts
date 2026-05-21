// src/main/windows/createBrowserWindow.ts
import { BrowserWindow } from 'electron'
import { registerReaderContextMenu } from '../contextMenu'
import type { WindowIdentity } from './windowManager'

export interface FactoryDeps {
  loadUrl: string // dev: ELECTRON_RENDERER_URL; prod: http://localhost:<port>
  preloadPath: string // path.join(__dirname, '../preload/index.js')
}

export function makeBrowserWindowFactory(deps: FactoryDeps) {
  return (identity: WindowIdentity): BrowserWindow => {
    const dims =
      identity.kind === 'settings'
        ? { width: 640, height: 720 }
        : identity.kind === 'library'
          ? { width: 1024, height: 770 }
          : { width: 1100, height: 900 }

    const win = new BrowserWindow({
      width: dims.width,
      height: dims.height,
      minWidth: identity.kind === 'settings' ? 480 : 800,
      minHeight: identity.kind === 'settings' ? 480 : 600,
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 15, y: 10 },
      show: false,
      webPreferences: {
        preload: deps.preloadPath,
        sandbox: false,
        contextIsolation: true,
        nodeIntegration: false,
        // epub.js renders book content inside `about:srcdoc` iframes, and
        // Chromium sandboxes those (blocking script execution + the 'rendered'
        // event) when webSecurity is enabled. Book windows therefore have to
        // run with webSecurity off. The library/settings windows don't render
        // book content, so we keep the default (true) for them — that's what
        // re-enables CSP enforcement and same-origin policy where it matters.
        webSecurity: identity.kind === 'book' ? false : true,
        additionalArguments: [`--window-identity=${identityFlag(identity)}`]
      }
    })
    win.on('ready-to-show', () => win.show())

    // Flush any in-flight saves before book windows actually close. The
    // renderer's save path is async (page-curl animation + epubjs render +
    // mutation + IPC ≈ 400-700ms after a click). If the user closes a book
    // window mid-flight, the new CFI never reaches SQLite. Intercept `close`,
    // ask the renderer to flush whatever it knows, then destroy.
    //
    // Only book windows have a flush handler registered in the renderer; the
    // library window has nothing to save, so we skip the hook entirely there
    // to avoid prolonging app-quit teardown.
    if (identity.kind === 'book') {
      let flushed = false
      win.on('close', (e) => {
        if (flushed) return
        if (win.webContents.isDestroyed()) return
        e.preventDefault()
        const FLUSH_TIMEOUT_MS = 1500
        const flushPromise = win.webContents
          .executeJavaScript(
            `(window.__rishi && typeof window.__rishi.flushPendingSaves === 'function')
              ? window.__rishi.flushPendingSaves()
              : null`,
            true
          )
          .catch((err: unknown) => {
            console.error('[createBrowserWindow] flush threw', err)
          })
        const timeoutPromise = new Promise<void>((resolve) => {
          setTimeout(resolve, FLUSH_TIMEOUT_MS)
        })
        void Promise.race([flushPromise, timeoutPromise]).then(() => {
          flushed = true
          if (!win.isDestroyed()) win.destroy()
        })
      })
    }

    const hash =
      identity.kind === 'book'
        ? `#/books/${identity.bookId}`
        : identity.kind === 'settings'
          ? '#/settings/account'
          : '#/'
    win.loadURL(`${deps.loadUrl}${hash}`).catch((err: unknown) => {
      console.error('[createBrowserWindow] loadURL failed', err)
    })
    registerReaderContextMenu(win)
    return win
  }
}

function identityFlag(i: WindowIdentity): string {
  if (i.kind === 'book') return `book:${i.bookId}`
  if (i.kind === 'settings') return 'settings'
  return 'library'
}

export const __forTest = { identityFlag }
