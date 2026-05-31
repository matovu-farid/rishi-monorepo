import * as fs from 'node:fs/promises'
import * as path from 'node:path'

/**
 * Read the user's `autoUpdateEnabled` preference from the on-disk settings
 * store. Returns `true` (auto-update ON) for every ambiguous case — missing
 * file, missing key, non-boolean garbage, corrupt JSON — so a damaged
 * store can never silently disable updates and strand users on an old build.
 *
 * `userDataPath` is `app.getPath('userData')` in production; the parameter
 * makes the function unit-testable without spinning up Electron.
 */
export async function readAutoUpdatePref(userDataPath: string): Promise<boolean> {
  try {
    const raw = await fs.readFile(path.join(userDataPath, 'settings-store.json'), 'utf-8')
    const parsed: unknown = JSON.parse(raw)
    if (parsed && typeof parsed === 'object' && 'autoUpdateEnabled' in parsed) {
      const value = (parsed as Record<string, unknown>).autoUpdateEnabled
      if (typeof value === 'boolean') return value
    }
    return true
  } catch {
    return true
  }
}
