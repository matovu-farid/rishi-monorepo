import { AppState, type AppStateStatus } from 'react-native'
import type { NativeEventSubscription } from 'react-native'
import { sync } from './engine'

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

  // Initial sync on start
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
