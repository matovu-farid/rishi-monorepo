/**
 * Dev-only state dump.
 *
 * Periodically snapshots app state (player, TTS queue, auth, etc.)
 * to state-dump.json for debugging. No-op in production.
 */
import { usePlayerStore } from '../stores/playerStore'
import { ttsQueue } from '../modules/ttsQueue'
import { ttsService } from '../modules/ttsService'

const IS_DEV = import.meta.env.DEV

interface StateDumpEntry {
  timestamp: string
  event: string
  data: Record<string, unknown>
}

const history: StateDumpEntry[] = []
const MAX_HISTORY = 50

/** Log a state event to the history ring buffer. */
export function logStateEvent(event: string, data: Record<string, unknown> = {}): void {
  if (!IS_DEV) return
  history.push({
    timestamp: new Date().toISOString(),
    event,
    data
  })
  if (history.length > MAX_HISTORY) {
    history.shift()
  }
  // Write on each event for real-time debugging
  void writeStateDump()
}

async function buildStateDump(): Promise<Record<string, unknown>> {
  const playerState = usePlayerStore.getState()
  const queueStatus = ttsQueue.getQueueStatus()

  let devMode: boolean | null = null
  let hasToken = false
  try {
    devMode = await window.electron.isDev()
  } catch {
    /* ignore */
  }
  try {
    const { getAuthToken } = await import('../modules/auth')
    const token = await getAuthToken()
    hasToken = !!token
  } catch {
    /* ignore */
  }

  return {
    timestamp: new Date().toISOString(),
    player: {
      playingState: playerState.playingState,
      activeParagraph: playerState.activeParagraph?.text?.substring(0, 80) ?? null,
      errors: playerState.errors
    },
    ttsQueue: queueStatus,
    ttsService: {
      activeRequests: (ttsService as any).activeRequests?.size ?? 0,
      pendingListeners: (ttsService as any).pendingListeners?.size ?? 0
    },
    auth: { devMode, hasToken },
    history
  }
}

async function writeStateDump(): Promise<void> {
  if (!IS_DEV) return
  try {
    const dump = await buildStateDump()
    const json = JSON.stringify(dump, null, 2)
    await window.electron.dumpError({
      source: 'state-dump',
      location: 'periodic',
      error: json
    })
  } catch {
    // Best effort -- don't break the app
  }
}

let intervalId: ReturnType<typeof setInterval> | null = null

/** Start periodic state dumps + event-driven dumps. */
export function installStateDump(): void {
  if (!IS_DEV) return

  // Write initial state
  void writeStateDump()

  // Periodic snapshot every 5 seconds
  intervalId = setInterval(() => {
    void writeStateDump()
  }, 5000)
}

export function stopStateDump(): void {
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
}
