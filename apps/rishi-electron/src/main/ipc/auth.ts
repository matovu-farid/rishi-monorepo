import { ipcMain, app } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'

/** Path to the cached user profile JSON file. */
function getUserStorePath(): string {
  return path.join(app.getPath('userData'), 'user.json')
}

export function registerAuthHandlers(): void {
  ipcMain.handle('auth:clear', async () => {
    try {
      await fs.unlink(getUserStorePath()).catch(() => {})
    } catch (error) {
      throw new Error(
        `Failed to clear auth: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:getUserFromStore', async () => {
    try {
      const userPath = getUserStorePath()

      try {
        await fs.access(userPath)
      } catch {
        return null
      }

      const data = await fs.readFile(userPath, 'utf-8')
      return JSON.parse(data)
    } catch (error) {
      throw new Error(
        `Failed to get user from store: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:saveUserToStore', async (_event, user: unknown) => {
    try {
      const userPath = getUserStorePath()
      await fs.writeFile(userPath, JSON.stringify(user, null, 2))
    } catch (error) {
      throw new Error(
        `Failed to save user to store: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
