import { app } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

function getStorePath(): string {
  return path.join(app.getPath('userData'), 'settings-store.json')
}

function getStoreTmpPath(): string {
  return `${getStorePath()}.tmp`
}

async function readStore(): Promise<Record<string, unknown>> {
  try {
    const data = await fs.readFile(getStorePath(), 'utf-8')
    return JSON.parse(data)
  } catch {
    return {}
  }
}

// Atomic write: write to a sibling .tmp file then rename over the target.
// POSIX `rename(2)` is atomic on the same filesystem; Windows `MoveFileEx`
// with the same volume is also atomic for our purposes. If the process
// crashes before the rename, the original file is untouched.
async function writeStoreAtomic(store: Record<string, unknown>): Promise<void> {
  const target = getStorePath()
  const tmp = getStoreTmpPath()
  const payload = JSON.stringify(store, null, 2)
  await fs.writeFile(tmp, payload)
  await fs.rename(tmp, target)
}

// All store mutations funnel through this promise chain so concurrent
// `store:set` calls cannot interleave their read-modify-write cycle.
// Each task runs after the previous one settles, success or failure.
let writeQueue: Promise<unknown> = Promise.resolve()

function enqueueWrite<T>(task: () => Promise<T>): Promise<T> {
  const next = writeQueue.then(task, task)
  // Swallow rejections on the chain itself so a single failing task does not
  // poison every subsequent write. Callers still see the error via `next`.
  writeQueue = next.catch(() => undefined)
  return next
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
      await enqueueWrite(async () => {
        const store = await readStore()
        store[key] = value
        await writeStoreAtomic(store)
      })
    } catch (error) {
      throw new Error(`Failed to set store key "${key}": ${errorMessage(error)}`)
    }
  })
}
