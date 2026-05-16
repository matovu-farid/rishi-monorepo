// src/main/windows/createBrowserWindow.ts
import { BrowserWindow } from 'electron'
import type { WindowIdentity } from './windowManager'

export interface FactoryDeps {
  loadUrl: string // dev: ELECTRON_RENDERER_URL; prod: http://localhost:<port>
  preloadPath: string // path.join(__dirname, '../preload/index.js')
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
        const timeoutPromise = new Promise<void>((resolve) =>
          setTimeout(resolve, FLUSH_TIMEOUT_MS)
        )
        void Promise.race([flushPromise, timeoutPromise]).then(() => {
          flushed = true
          if (!win.isDestroyed()) win.destroy()
        })
      })
    }

    const hash = identity.kind === 'book' ? `#/books/${identity.bookId}` : '#/'
    win.loadURL(`${deps.loadUrl}${hash}`).catch((err: unknown) => {
      console.error('[createBrowserWindow] loadURL failed', err)
    })
    return win
  }
}

function identityFlag(i: WindowIdentity): string {
  return i.kind === 'book' ? `book:${i.bookId}` : 'library'
}

export const __forTest = { identityFlag }
