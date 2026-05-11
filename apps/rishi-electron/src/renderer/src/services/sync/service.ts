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

      // apiFetch is built once and closed over the adapter; the engine
      // factory binds them together. For Task 10 we pass a no-op
      // apiFetch — Task 16 wires the real auth-aware wrapper.
      const adapter = makeAdapter(ipc)
      const apiFetch = async (): Promise<Response> =>
        new Response('{}', { status: 200 })
      engine = engineFactory({ adapter, apiFetch })

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
