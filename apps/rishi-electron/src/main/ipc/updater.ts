import { autoUpdater } from 'electron-updater'
import { BrowserWindow, app } from 'electron'
import { is } from '@electron-toolkit/utils'
import { handle } from '../../preload/ipc-contract.js'
import { readAutoUpdatePref } from './updaterPref.js'

/**
 * Register IPC handlers for the auto-updater.
 *
 * The renderer triggers checks / downloads / installs via IPC invoke.
 * autoUpdater events are forwarded to all renderer windows so the UI
 * can track progress.
 */
export function registerUpdaterHandlers(): void {
  // ── Configure autoUpdater ────────────────────────────────────────────
  // `autoDownload` is set per check based on the user's `autoUpdateEnabled`
  // preference. `autoInstallOnAppQuit` stays on so a downloaded update is
  // applied the next time the user quits — no restart prompt, no banners.
  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true
  autoUpdater.logger = console

  // ── Helper: send an event to all renderer windows ────────────────────
  function sendToRenderers(channel: string, ...args: unknown[]): void {
    for (const win of BrowserWindow.getAllWindows()) {
      if (!win.isDestroyed()) {
        win.webContents.send(channel, ...args)
      }
    }
  }

  // ── Forward autoUpdater events to the renderer ───────────────────────
  autoUpdater.on('update-available', (info) => {
    sendToRenderers('update-available', {
      version: info.version,
      releaseNotes: info.releaseNotes ?? null
    })
  })

  autoUpdater.on('update-not-available', () => {
    sendToRenderers('update-not-available')
  })

  autoUpdater.on('download-progress', (progress) => {
    sendToRenderers('download-progress', {
      percent: progress.percent,
      bytesPerSecond: progress.bytesPerSecond,
      transferred: progress.transferred,
      total: progress.total
    })
  })

  autoUpdater.on('update-downloaded', (info) => {
    sendToRenderers('update-downloaded', {
      version: info.version,
      releaseNotes: info.releaseNotes ?? null
    })
  })

  autoUpdater.on('error', (err) => {
    sendToRenderers('update-error', err.message)
  })

  // ── IPC handlers ─────────────────────────────────────────────────────

  handle('updater:check', async () => {
    // Skip update checks in dev mode — there are no published builds to compare against.
    if (is.dev) {
      console.log('[updater] Skipping update check in dev mode')
      return { updateAvailable: false }
    }
    // Honour the user's opt-out: when auto-update is disabled, the silent
    // startup check should be a no-op. (Manual checks from the menu use
    // the same handler today; opting out also pauses those — flip the
    // toggle in Settings to resume.)
    const autoEnabled = await readAutoUpdatePref(app.getPath('userData'))
    if (!autoEnabled) {
      console.log('[updater] Auto-update disabled by user preference; skipping check')
      autoUpdater.autoDownload = false
      return { updateAvailable: false }
    }
    autoUpdater.autoDownload = true
    try {
      const result = await autoUpdater.checkForUpdates()
      return {
        updateAvailable: !!result?.updateInfo,
        version: result?.updateInfo.version ?? null
      }
    } catch (err) {
      console.error('[updater] checkForUpdates failed:', err)
      throw err
    }
  })

  handle('updater:download', async () => {
    if (is.dev) {
      console.log('[updater] Skipping download in dev mode')
      return
    }
    try {
      await autoUpdater.downloadUpdate()
    } catch (err) {
      console.error('[updater] downloadUpdate failed:', err)
      throw err
    }
  })

  handle('updater:install', () => {
    // quitAndInstall will close all windows, then launch the installer
    autoUpdater.quitAndInstall()
  })

  handle('updater:getAppVersion', () => {
    return app.getVersion()
  })
}
