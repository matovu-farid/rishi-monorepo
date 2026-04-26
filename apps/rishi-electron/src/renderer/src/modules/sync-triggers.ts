/**
 * Sync engine initialization and triggers.
 * Ported from Tauri version - uses createSyncEngine from shared package.
 */
import { createSyncEngine, type SyncEngine } from '@rishi/shared/sync-engine'
import { DesktopSyncAdapter } from './sync-adapter'
import { getAuthToken } from './auth'

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev'
const SYNC_INTERVAL_MS = 5 * 60 * 1000 // 5 minutes

export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline'

type SyncStatusListener = (status: SyncStatus, lastSyncAt: number | null) => void

let engine: SyncEngine | null = null
let syncStatus: SyncStatus = 'not-synced'
let lastSyncAt: number | null = null
let intervalId: ReturnType<typeof setInterval> | null = null
let focusHandler: (() => void) | null = null
let onlineHandler: (() => void) | null = null
let offlineHandler: (() => void) | null = null
const listeners: Set<SyncStatusListener> = new Set()

function notifyListeners() {
  for (const listener of listeners) {
    listener(syncStatus, lastSyncAt)
  }
}

export function onSyncStatusChange(listener: SyncStatusListener): () => void {
  listeners.add(listener)
  // Immediately call with current state
  listener(syncStatus, lastSyncAt)
  return () => listeners.delete(listener)
}

export function getSyncStatus(): { status: SyncStatus; lastSyncAt: number | null } {
  return { status: syncStatus, lastSyncAt }
}

async function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  const makeRequest = async (token: string | null): Promise<Response> => {
    const headers: Record<string, string> = {
      ...(init?.headers as Record<string, string>),
      'Content-Type': 'application/json'
    }

    if (token === 'dev-placeholder-token') {
      const secret = await window.electron.getDevBypassSecret()
      if (secret) {
        headers['X-Dev-Bypass'] = secret
      } else {
        // No bypass secret configured -- skip the request silently
        return new Response(JSON.stringify({ error: 'Not authenticated (dev)' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' }
        })
      }
    } else if (token) {
      headers['Authorization'] = `Bearer ${token}`
    }

    const syncController = new AbortController()
    const syncTimeout = setTimeout(() => syncController.abort(), 30_000)

    // If caller provided a signal, forward its abort to our controller
    if (init?.signal) {
      init.signal.addEventListener('abort', () => syncController.abort(), { once: true })
    }

    try {
      const response = await fetch(`${WORKER_URL}${path}`, {
        ...init,
        headers,
        signal: syncController.signal
      })
      return response
    } catch (err) {
      if (syncController.signal.aborted && !init?.signal?.aborted) {
        throw new Error(`Sync request to ${path} timed out after 30 seconds`)
      }
      throw err
    } finally {
      clearTimeout(syncTimeout)
    }
  }

  const token = await getAuthToken()
  const response = await makeRequest(token)

  // Retry once on 401 with a fresh token (may have expired during the request)
  if (response.status === 401 && token !== 'dev-placeholder-token') {
    const freshToken = await getAuthToken()
    if (freshToken && freshToken !== token) {
      return makeRequest(freshToken)
    }
  }

  return response
}

export async function triggerSync(): Promise<void> {
  if (!engine) return
  if (syncStatus === 'syncing') return

  // Set immediately before any async work to prevent concurrent calls
  syncStatus = 'syncing'
  notifyListeners()

  try {
    // Proactive token refresh before sync — matches Tauri behavior
    try {
      await window.electron.refreshAuthToken()
    } catch {
      /* best-effort */
    }
    await engine.sync()
    syncStatus = 'synced'
    lastSyncAt = Date.now()
  } catch (error) {
    console.warn('[desktop-sync] sync failed:', error)
    if (error instanceof Error && error.message === 'AUTH_EXPIRED') {
      syncStatus = 'error'
      console.warn('[desktop-sync] auth expired -- user must re-authenticate')
      window.dispatchEvent(new CustomEvent('sync-auth-expired'))
    } else if (!navigator.onLine) {
      syncStatus = 'offline'
    } else {
      syncStatus = 'error'
    }
  } finally {
    if (syncStatus === 'syncing') {
      // Should not happen, but guard against forgotten status update
      syncStatus = 'error'
    }
    notifyListeners()
  }
}

export function initDesktopSync(): void {
  if (engine) return // already initialized

  const adapter = new DesktopSyncAdapter()
  engine = createSyncEngine({ adapter, apiFetch })

  // Sync on app focus
  focusHandler = () => {
    void triggerSync()
  }
  window.addEventListener('focus', focusHandler)

  // Online/offline detection
  onlineHandler = () => {
    if (syncStatus === 'offline') void triggerSync()
  }
  window.addEventListener('online', onlineHandler)

  offlineHandler = () => {
    syncStatus = 'offline'
    notifyListeners()
  }
  window.addEventListener('offline', offlineHandler)

  // Periodic sync every 5 minutes
  intervalId = setInterval(() => {
    if (navigator.onLine) {
      void triggerSync()
    }
  }, SYNC_INTERVAL_MS)

  // Initial sync
  void triggerSync()
}

export function destroyDesktopSync(): void {
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
  if (focusHandler) {
    window.removeEventListener('focus', focusHandler)
    focusHandler = null
  }
  if (onlineHandler) {
    window.removeEventListener('online', onlineHandler)
    onlineHandler = null
  }
  if (offlineHandler) {
    window.removeEventListener('offline', offlineHandler)
    offlineHandler = null
  }
  engine = null
}

/**
 * Debounced sync trigger for local writes.
 * Fires triggerSync() 2 seconds after the last write, coalescing rapid writes.
 */
let writeTimeout: ReturnType<typeof setTimeout> | null = null
export function triggerSyncOnWrite(): void {
  if (writeTimeout) clearTimeout(writeTimeout)
  writeTimeout = setTimeout(() => {
    void triggerSync()
  }, 2000)
}
