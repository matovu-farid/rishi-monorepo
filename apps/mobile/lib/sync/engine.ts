/**
 * Mobile sync engine — thin wrapper over the shared
 * `createSyncEngine` from `@rishi/shared/sync-engine`.
 *
 * The actual push / pull logic lives in the shared package. This wrapper
 * adds the *mobile-specific* lifecycle bits:
 *   - `markSyncInProgress` toggling (sqlite WAL marker for interrupted-sync
 *     recovery on next launch)
 *   - `setSyncStatus(...)` listener notifications
 *
 * The public `sync()` export shape is unchanged, so existing callers
 * (`triggers.ts`, app code) keep working without modification.
 */
import { createSyncEngine } from '@rishi/shared/sync-engine'
import { apiClient } from '@/lib/api'
import { markSyncInProgress } from '@/lib/db'
import { createMobileDrizzleAdapter } from './drizzle-adapter'
import { setSyncStatus } from './status'

// Construct the engine once at module load. The adapter and apiClient
// are both module-scope singletons, so this is safe.
const engine = createSyncEngine({
  adapter: createMobileDrizzleAdapter(),
  apiFetch: apiClient,
})

let isSyncing = false

/**
 * Run a full push-then-pull sync cycle.
 *
 * A persistent marker is written before the cycle starts so an
 * interrupted sync (e.g. app killed mid-cycle) is detected on next launch.
 * All errors are caught internally — this function never throws.
 */
export async function sync(): Promise<void> {
  if (isSyncing) return
  isSyncing = true
  setSyncStatus('syncing')
  let syncError = false
  markSyncInProgress(true)
  try {
    await engine.push()
    await engine.pull()
    markSyncInProgress(false)
  } catch (error) {
    markSyncInProgress(false)
    syncError = true
    setSyncStatus('error')
    console.warn('[sync] cycle failed:', error)
  } finally {
    isSyncing = false
    if (!syncError) setSyncStatus('synced')
  }
}
