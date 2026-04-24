import { AppState, type AppStateStatus } from 'react-native'
import type { NativeEventSubscription } from 'react-native'
import { sync } from './engine'
import { wasSyncInterrupted } from '@/lib/db'

let syncInterval: ReturnType<typeof setInterval> | null = null
let writeDebounce: ReturnType<typeof setTimeout> | null = null
let appStateSubscription: NativeEventSubscription | null = null

/**
 * Start all automatic sync triggers:
 * - On app foreground (AppState 'active')
 * - Every 5 minutes (setInterval)
 * - Immediate initial sync
 */
export function startSyncTriggers(): void {
  // Guard against double-start
  stopSyncTriggers()

  // Trigger on app foreground
  appStateSubscription = AppState.addEventListener(
    'change',
    (nextState: AppStateStatus) => {
      if (nextState === 'active') {
        sync()
      }
    }
  )

  // Periodic sync every 5 minutes
  syncInterval = setInterval(() => {
    sync()
  }, 5 * 60 * 1000)

  // If a previous sync was interrupted (app killed mid-cycle), re-sync immediately
  if (wasSyncInterrupted()) {
    console.warn('[sync] Previous sync was interrupted, re-syncing')
  }

  // Initial sync on start (also covers interrupted-sync recovery)
  sync()
}

/**
 * Trigger a sync after a local write, debounced to 2 seconds.
 * Multiple calls within the debounce window reset the timer.
 */
export function triggerSyncOnWrite(): void {
  if (writeDebounce) {
    clearTimeout(writeDebounce)
  }
  writeDebounce = setTimeout(() => {
    sync()
    writeDebounce = null
  }, 2000)
}

/**
 * Stop all sync triggers and clean up subscriptions.
 */
export function stopSyncTriggers(): void {
  if (syncInterval) {
    clearInterval(syncInterval)
    syncInterval = null
  }
  if (writeDebounce) {
    clearTimeout(writeDebounce)
    writeDebounce = null
  }
  if (appStateSubscription) {
    appStateSubscription.remove()
    appStateSubscription = null
  }
}
