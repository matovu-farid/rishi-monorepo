import { app, shell } from 'electron'
import * as os from 'node:os'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

/**
 * Security boundary: the renderer can only ask the OS to open URLs whose
 * protocol is in this allow-list. Anything else (file:, javascript:,
 * vscode:, chrome-extension:, ...) is a renderer-to-OS escape and must be
 * rejected. Exported so the allow-list can be unit-tested without standing
 * up Electron.
 */
const OPEN_EXTERNAL_ALLOWED_PROTOCOLS = new Set(['http:', 'https:', 'mailto:'])

export function isOpenExternalUrlAllowed(url: string): boolean {
  try {
    const parsed = new URL(url)
    return OPEN_EXTERNAL_ALLOWED_PROTOCOLS.has(parsed.protocol)
  } catch {
    return false
  }
}

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
      if (!isOpenExternalUrlAllowed(url)) {
        const parsed = (() => {
          try {
            return new URL(url)
          } catch {
            return null
          }
        })()
        throw new Error(`Unsupported protocol: ${parsed?.protocol ?? '(invalid URL)'}`)
      }
      await shell.openExternal(url)
    } catch (error) {
      throw new Error(`Failed to open external URL: ${errorMessage(error)}`)
    }
  })
}
