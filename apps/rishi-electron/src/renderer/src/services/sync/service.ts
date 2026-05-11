import type {
  EngineLike,
  SyncService,
  SyncServiceDeps,
  SyncStatus,
  SyncStatusListener,
  SyncStatusSnapshot
} from './types'
import { makeAdapter } from './adapter'
import { createDebouncer } from './debounce'
import { createEmitter } from './emitter'

interface ApiFetchDeps {
  fetch: SyncServiceDeps['fetch']
  getAuthToken: SyncServiceDeps['getAuthToken']
  getDevBypassSecret: SyncServiceDeps['getDevBypassSecret']
  workerUrl: string
  requestTimeoutMs: number
}

function createApiFetch(
  deps: ApiFetchDeps
): (path: string, init?: RequestInit) => Promise<Response> {
  return async function apiFetch(path: string, init?: RequestInit): Promise<Response> {
    const token = await deps.getAuthToken()

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), deps.requestTimeoutMs)
    if (init?.signal) {
      init.signal.addEventListener('abort', () => controller.abort(), { once: true })
    }

    try {
      const headers: Record<string, string> = {
        ...((init?.headers as Record<string, string>) ?? {}),
        'Content-Type': 'application/json'
      }
      if (token) {
        headers['Authorization'] = `Bearer ${token}`
      } else {
        const secret = await deps.getDevBypassSecret()
        if (secret) {
          headers['X-Dev-Bypass'] = secret
        } else {
          return new Response(JSON.stringify({ error: 'Not authenticated' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' }
          })
        }
      }

      let response = await deps.fetch(`${deps.workerUrl}${path}`, {
        ...init,
        headers,
        signal: controller.signal
      })

      // Retry once on 401 with a freshly-minted token.
      if (response.status === 401 && token) {
        const freshToken = await deps.getAuthToken()
        if (freshToken && freshToken !== token) {
          const retryHeaders = { ...headers, Authorization: `Bearer ${freshToken}` }
          response = await deps.fetch(`${deps.workerUrl}${path}`, {
            ...init,
            headers: retryHeaders,
            signal: controller.signal
          })
        }
      }
      return response
    } finally {
      clearTimeout(timeout)
    }
  }
}

export function createSyncService(deps: SyncServiceDeps): SyncService {
  const { ipc, engineFactory, connectivity, clock, windowEvents, config } = deps

  const emitter = createEmitter<SyncStatusSnapshot>()
  const debouncer = createDebouncer(clock, config.debounceMs)
  let engine: EngineLike | null = null
  let status: SyncStatus = 'not-synced'
  let lastSyncAt: number | null = null
  let intervalHandle: ReturnType<typeof clock.setInterval> | null = null
  let connectivityUnsub: (() => void) | null = null
  let focusHandler: EventListener | null = null
  let started = false

  function snapshot(): SyncStatusSnapshot {
    return { status, lastSyncAt }
  }

  function setStatus(next: SyncStatus): void {
    status = next
    emitter.emit(snapshot())
  }

  async function runSync(): Promise<void> {
    if (!engine) return
    if (status === 'syncing') return
    const currentEngine = engine
    setStatus('syncing')
    try {
      await currentEngine.sync()
      if (engine !== currentEngine) return // stop() ran during sync
      lastSyncAt = clock.now()
      setStatus('synced')
    } catch (err) {
      if (engine !== currentEngine) return
      if (err instanceof Error && err.message === 'AUTH_EXPIRED') {
        windowEvents.dispatchEvent(new CustomEvent('sync-auth-expired'))
        setStatus('error')
      } else if (!connectivity.isOnline()) {
        setStatus('offline')
      } else {
        setStatus('error')
      }
    }
  }

  return {
    start() {
      if (started) return
      started = true

      const adapter = makeAdapter(ipc)
      const apiFetch = createApiFetch({
        fetch: deps.fetch,
        getAuthToken: deps.getAuthToken,
        getDevBypassSecret: deps.getDevBypassSecret,
        workerUrl: config.workerUrl,
        requestTimeoutMs: config.requestTimeoutMs
      })
      engine = engineFactory({ adapter, apiFetch })

      focusHandler = () => {
        void runSync()
      }
      windowEvents.addEventListener('focus', focusHandler)

      connectivityUnsub = connectivity.subscribe((online) => {
        if (online && status === 'offline') {
          void runSync()
        } else if (!online) {
          setStatus('offline')
        }
      })

      intervalHandle = clock.setInterval(() => {
        if (connectivity.isOnline()) void runSync()
      }, config.intervalMs)

      void runSync()
    },

    stop() {
      if (!started) return
      started = false
      debouncer.cancel()
      if (intervalHandle != null) clock.clearInterval(intervalHandle)
      intervalHandle = null
      if (focusHandler) windowEvents.removeEventListener('focus', focusHandler)
      focusHandler = null
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
      engine = null
      // Reset status so a subsequent start() (e.g. React StrictMode remount or
      // sign-out/sign-in) isn't blocked by the `status === 'syncing'` guard in
      // runSync(). The in-flight runSync still bails via its engine-identity
      // check, so we won't emit a stale 'synced' from the prior engine.
      setStatus('not-synced')
    },

    triggerWrite() {
      if (!started) return
      if (!connectivity.isOnline()) return
      debouncer.trigger(() => {
        void runSync()
      })
    },

    getStatus() {
      return snapshot()
    },

    onStatusChange(listener: SyncStatusListener) {
      const unsub = emitter.on(listener)
      listener(snapshot())
      return unsub
    }
  }
}
