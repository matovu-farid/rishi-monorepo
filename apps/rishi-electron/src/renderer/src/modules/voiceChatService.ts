import type { RealtimeSession } from '@openai/agents/realtime'
import { getOrFetchKey, prefetchRealtimeKey } from './realtime'
import { buildRealtimeAgent } from './buildRealtimeAgent'
import { captureError } from '@/utils/sentry'

export type VoiceChatState = 'idle' | 'connecting' | 'active' | 'paused' | 'disposing'

export interface VoiceChatEvents {
  onStateChange: (state: VoiceChatState) => void
  onChatStatusChange: (status: 'idle' | 'connecting' | 'thinking' | 'speaking') => void
  onEndedByAgent: () => void
}

const IDLE_TIMEOUT_MS = 15 * 60 * 1000

// Module-level singleton state
let state: VoiceChatState = 'idle'
let session: RealtimeSession | null = null
let currentBookId: number | null = null
let idleTimer: ReturnType<typeof setTimeout> | null = null
let mediaStream: MediaStream | null = null
let audioElement: HTMLAudioElement | null = null
let listeners: Partial<VoiceChatEvents> = {}

function setState(next: VoiceChatState) {
  if (state === next) return
  state = next
  listeners.onStateChange?.(state)
}

function clearIdleTimer() {
  if (idleTimer) {
    clearTimeout(idleTimer)
    idleTimer = null
  }
}

function scheduleIdleTimer() {
  clearIdleTimer()
  idleTimer = setTimeout(() => {
    voiceChatService.dispose()
  }, IDLE_TIMEOUT_MS)
}

export const voiceChatService = {
  getState(): VoiceChatState {
    return state
  },

  setListeners(next: Partial<VoiceChatEvents>) {
    listeners = { ...listeners, ...next }
  },

  /** Prefetch the OpenAI ephemeral key — safe to call on book open. Does NOT prompt for mic. */
  prewarmKey() {
    prefetchRealtimeKey()
  },

  /**
   * Start or resume voice chat for the given book.
   * - First call: full setup (mic prompt + WebRTC handshake + agent build) — Task 3 wires this.
   * - Subsequent call on same book: updateAgent + unmute (near-instant).
   * - Call on different book: dispose old session, then full setup for new book.
   */
  async activate(bookId: number, pageText: string): Promise<void> {
    clearIdleTimer()

    // Book switched while a session is alive — fully dispose first
    if (session && currentBookId !== null && currentBookId !== bookId) {
      this.dispose()
    }

    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text, then unmute
      setState('connecting')
      try {
        const newAgent = buildRealtimeAgent({
          bookId,
          pageText,
          onEndConversation: () => listeners.onEndedByAgent?.()
        })
        await session.updateAgent(newAgent as never)
        session.mute(false)
        if (audioElement) audioElement.muted = false
        setState('active')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        setState('idle')
        throw err
      }
      return
    }

    // Cold path — wired in Task 3. For now, throw so tests are clear.
    throw new Error('voiceChatService.activate cold path not yet implemented')
  },

  deactivate() {
    if (!session) return
    try {
      session.interrupt()
      session.mute(true)
      if (audioElement) audioElement.muted = true
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'deactivate' })
    }
    setState('paused')
    listeners.onChatStatusChange?.('idle')
    scheduleIdleTimer()
  },

  dispose() {
    clearIdleTimer()
    const s = session
    session = null
    currentBookId = null
    if (s) {
      try {
        s.close()
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'dispose_close' })
      }
    }
    if (mediaStream) {
      mediaStream.getTracks().forEach((t) => t.stop())
      mediaStream = null
    }
    audioElement = null
    setState('idle')
    listeners.onChatStatusChange?.('idle')
  },

  // --- test hooks ---
  _resetForTests() {
    clearIdleTimer()
    session = null
    currentBookId = null
    mediaStream = null
    audioElement = null
    listeners = {}
    state = 'idle'
  },
  _setSessionForTests(fakeSession: RealtimeSession, bookId: number) {
    session = fakeSession
    currentBookId = bookId
    state = 'active'
  }
}

// Re-export for convenience
export { getOrFetchKey }
