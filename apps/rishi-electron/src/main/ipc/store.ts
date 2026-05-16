import { app } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

function getStorePath(): string {
  return path.join(app.getPath('userData'), 'settings-store.json')
}

async function readStore(): Promise<Record<string, unknown>> {
  try {
    const data = await fs.readFile(getStorePath(), 'utf-8')
    return JSON.parse(data)
  } catch {
    return {}
  }
}

async function writeStore(store: Record<string, unknown>): Promise<void> {
  await fs.writeFile(getStorePath(), JSON.stringify(store, null, 2))
}

export function registerStoreHandlers(): void {
  handle('store:get', async (_event, key) => {
    try {
      const store = await readStore()
      return store[key] ?? null
    } catch (error) {
      throw new Error(`Failed to get store key "${key}": ${errorMessage(error)}`)
    }
  })

  handle('store:set', async (_event, key, value) => {
    try {
      const store = await readStore()
      store[key] = value
      await writeStore(store)
    } catch (error) {
      throw new Error(`Failed to set store key "${key}": ${errorMessage(error)}`)
    }
  })
}
