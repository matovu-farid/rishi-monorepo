import { app, shell } from 'electron'
import * as os from 'node:os'
import { handle } from '../../preload/ipc-contract.js'

export function registerUtilHandlers(): void {
  handle('util:isDev', () => {
    return !app.isPackaged
  })

  handle('util:getDevBypassSecret', () => {
    return process.env.DEV_BYPASS_SECRET ?? null
  })

  handle('util:getOsInfo', () => {
    return {
      platform: process.platform,
      arch: process.arch,
      version: os.release()
    }
  })

  handle('shell:openExternal', async (_event, url) => {
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
