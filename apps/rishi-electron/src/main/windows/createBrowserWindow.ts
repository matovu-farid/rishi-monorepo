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
