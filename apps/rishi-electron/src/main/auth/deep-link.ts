import { app, BrowserWindow } from "electron"

export const DEEP_LINK_PROTOCOL = "rishi-electron"

export type DeepLinkCallback = (url: string) => void

/**
 * Registers `rishi-electron://` as a custom URL scheme owned by this app and
 * wires the OS-specific dispatch:
 *
 *   - macOS: app.on('open-url') fires with the URL
 *   - Windows / Linux: when the OS opens the URL, it relaunches the app with
 *     the URL appended to argv. Our single-instance lock catches the relaunch
 *     in the `second-instance` event (handled in src/main/index.ts).
 */
export function setupDeepLinkHandler(
  onCallback: DeepLinkCallback,
  getMainWindow: () => BrowserWindow | null,
): void {
  // Custom scheme registration
  if (process.defaultApp) {
    if (process.argv.length >= 2) {
      app.setAsDefaultProtocolClient(DEEP_LINK_PROTOCOL, process.execPath, [
        process.argv[1],
      ])
    }
  } else {
    app.setAsDefaultProtocolClient(DEEP_LINK_PROTOCOL)
  }

  // macOS dispatch
  app.on("open-url", (event, url) => {
    event.preventDefault()
    handleUrl(url, onCallback, getMainWindow)
  })

  // Windows / Linux dispatch — handled by the single-instance listener in
  // src/main/index.ts. Caller wires findDeepLinkInArgv + handleUrl there.
}

export function handleUrl(
  url: string,
  onCallback: DeepLinkCallback,
  getMainWindow: () => BrowserWindow | null,
): void {
  if (!url.startsWith(`${DEEP_LINK_PROTOCOL}://`)) return
  const win = getMainWindow()
  if (win) {
    if (win.isMinimized()) win.restore()
    win.focus()
  }
  onCallback(url)
}

/** Scan a process argv for a deep-link URL. Returns null if none found. */
export function findDeepLinkInArgv(argv: string[]): string | null {
  return argv.find((a) => a.startsWith(`${DEEP_LINK_PROTOCOL}://`)) ?? null
}
