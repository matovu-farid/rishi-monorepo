import type { BrowserWindow } from 'electron'
import { app } from 'electron'
import { resolve as resolvePath } from 'node:path'

const PROTOCOL = 'rishi'
let queued: string | null = null
let getMainWindow: (() => BrowserWindow | null) | null = null

/**
 * Initialise the `rishi://` deep-link handler. Registers the app as the
 * default protocol client, wires the `open-url` event (macOS), drains the
 * first-launch argv (Windows/Linux), and routes parsed join tokens to the
 * main library window. Tokens received before the window is ready are
 * buffered and drained via `drainQueuedDeepLink()` once it loads.
 */
export function initSharingDeepLink(get: () => BrowserWindow | null): void {
  getMainWindow = get
  if (process.defaultApp) {
    if (process.argv.length >= 2) {
      app.setAsDefaultProtocolClient(PROTOCOL, process.execPath, [resolvePath(process.argv[1])])
    }
  } else {
    app.setAsDefaultProtocolClient(PROTOCOL)
  }

  app.on('open-url', (event, url) => {
    event.preventDefault()
    handleUrl(url)
  })

  const fromArgv = process.argv.find((a) => a.startsWith(`${PROTOCOL}://`))
  if (fromArgv) handleUrl(fromArgv)
}

/**
 * Forward a `rishi://` URL captured from the second-instance argv into the
 * deep-link pipeline. Called from `app.on('second-instance')` so a second
 * launch with a deep-link argument is routed to the running instance.
 */
export function dispatchSecondInstanceArgv(argv: string[]): void {
  const url = argv.find((a) => a.startsWith(`${PROTOCOL}://`))
  if (url) handleUrl(url)
}

/**
 * Pure URL parser for `rishi://sharing/join?t=<token>`. Exported for direct
 * testing — the rest of this module wraps Electron event sources.
 */
export function parseJoinToken(url: string): string | null {
  try {
    const u = new URL(url)
    if (u.protocol !== `${PROTOCOL}:`) return null
    // Exact `/join` match — `startsWith('join')` would also accept `joinx`,
    // which is an auth-adjacent footgun. Split on `/` and check the first
    // non-empty segment matches exactly.
    if (u.host !== 'sharing') return null
    const segments = u.pathname.split('/').filter(Boolean)
    if (segments[0] !== 'join') return null
    return u.searchParams.get('t')
  } catch {
    return null
  }
}

function handleUrl(url: string): void {
  const token = parseJoinToken(url)
  if (!token) return
  const win = getMainWindow?.()
  if (win && !win.isDestroyed()) {
    win.webContents.send('sharing:deepLinkReceived', { joinToken: token })
    if (win.isMinimized()) win.restore()
    win.focus()
  } else {
    queued = token
  }
}

/**
 * Returns and clears any deep-link join token that arrived before the
 * renderer was ready. Call from `did-finish-load` to flush the buffer.
 */
export function drainQueuedDeepLink(): string | null {
  const t = queued
  queued = null
  return t
}
