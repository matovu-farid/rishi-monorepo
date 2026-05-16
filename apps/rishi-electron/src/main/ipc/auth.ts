import { app } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import type { User } from '../../preload/types.js'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

/** Path to the cached user profile JSON file. */
function getUserStorePath(): string {
  return path.join(app.getPath('userData'), 'user.json')
}

export function registerAuthHandlers(): void {
  handle('auth:clear', async () => {
    try {
      await fs.unlink(getUserStorePath()).catch(() => {})
    } catch (error) {
      throw new Error(`Failed to clear auth: ${errorMessage(error)}`)
    }
  })

  handle('auth:getUserFromStore', async () => {
    try {
      const userPath = getUserStorePath()

      try {
        await fs.access(userPath)
      } catch {
        return null
      }

      const data = await fs.readFile(userPath, 'utf-8')
      return JSON.parse(data) as User
    } catch (error) {
      throw new Error(`Failed to get user from store: ${errorMessage(error)}`)
    }
  })

  handle('auth:saveUserToStore', async (_event, user) => {
    try {
      const userPath = getUserStorePath()
      await fs.writeFile(userPath, JSON.stringify(user, null, 2))
    } catch (error) {
      throw new Error(`Failed to save user to store: ${errorMessage(error)}`)
    }
  })
}
