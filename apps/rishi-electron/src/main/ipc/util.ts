import { ipcMain, app, shell } from 'electron'
import * as os from 'node:os'

export function registerUtilHandlers(): void {
  ipcMain.handle('util:isDev', async () => {
    return !app.isPackaged
  })

  ipcMain.handle('util:getDevBypassSecret', async () => {
    return process.env.DEV_BYPASS_SECRET ?? null
  })

  ipcMain.handle('util:getOsInfo', async () => {
    return {
      platform: process.platform,
      arch: process.arch,
      version: os.release()
    }
  })

  ipcMain.handle('shell:openExternal', async (_event, url: string) => {
    try {
      // Basic URL validation to prevent opening arbitrary protocols
      const parsed = new URL(url)
      if (!['http:', 'https:', 'mailto:'].includes(parsed.protocol)) {
        throw new Error(`Unsupported protocol: ${parsed.protocol}`)
      }
      await shell.openExternal(url)
    } catch (error) {
      throw new Error(
        `Failed to open external URL: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
