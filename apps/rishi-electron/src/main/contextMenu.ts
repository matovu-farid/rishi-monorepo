// src/main/contextMenu.ts
import { Menu, MenuItem, BrowserWindow } from 'electron'

/**
 * Registers a context-menu listener on the given BrowserWindow's webContents
 * that surfaces a single "Read Aloud From Here" item when the user
 * right-clicks on selected text. Sends `reader:readAloudFromSelection` to
 * the renderer when chosen.
 *
 * Electron fires `context-menu` for any frame including iframes — the EPUB
 * iframe's right-click is handled by this listener with no renderer-side
 * forwarding needed.
 */
export function registerReaderContextMenu(window: BrowserWindow): void {
  const wc = window.webContents
  wc.on('context-menu', (_event, params) => {
    const hasSelection = params.selectionText && params.selectionText.trim().length > 0
    if (!hasSelection) return

    const menu = new Menu()
    menu.append(
      new MenuItem({
        label: 'Read Aloud From Here',
        click: () => {
          wc.send('reader:readAloudFromSelection')
        }
      })
    )
    menu.popup({ window, x: params.x, y: params.y })
  })
}
