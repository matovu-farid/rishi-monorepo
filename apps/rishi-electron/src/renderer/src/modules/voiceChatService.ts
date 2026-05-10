import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import { getOrFetchKey, prefetchRealtimeKey } from './realtime'
import { buildRealtimeAgent } from './buildRealtimeAgent'
import { captureError } from '@/utils/sentry'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
import type { BookOutline } from '@/lib/api'

export type VoiceChatState = 'idle' | 'connecting' | 'active' | 'paused'

export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
}

export interface VoiceChatEvents {
  onStateChange: (state: VoiceChatState) => void
  onChatStatusChange: (status: 'idle' | 'connecting' | 'thinking' | 'speaking') => void
  onEndedByAgent: () => void
}

const IDLE_TIMEOUT_MS = 15 * 60 * 1000

// Module-level singleton state
let hasFiredReadyChime = false
let isAgentSpeaking = false
let state: VoiceChatState = 'idle'
let session: RealtimeSession | null = null
let sessionCleanup: (() => void) | null = null
let currentBookId: number | null = null
let idleTimer: ReturnType<typeof setTimeout> | null = null
let mediaStream: MediaStream | null = null
let audioElement: HTMLAudioElement | null = null
let listeners: Partial<VoiceChatEvents> = {}
let lastContextFingerprint: string | null = null

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

function fingerprintContext(ctx: VoiceChatContext): string {
  return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
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
  async activate(bookId: number, ctx: VoiceChatContext): Promise<void> {
    clearIdleTimer()

    // Book switched while a session is alive — fully dispose first
    if (session && currentBookId !== null && currentBookId !== bookId) {
      this.dispose()
    }

    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text (if changed), then unmute
      setState('connecting')
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const newAgent = buildRealtimeAgent({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            onEndConversation: () => listeners.onEndedByAgent?.()
          })
          await session.updateAgent(newAgent as never)
          lastContextFingerprint = fp
        }
        session.mute(false)
        if (audioElement) audioElement.muted = false
        setState('active')
        listeners.onChatStatusChange?.('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        setState('idle')
        throw err
      }
      return
    }

    // Cold path: first-time activation or after dispose
    setState('connecting')
    listeners.onChatStatusChange?.('connecting')

    try {
      // 1. Acquire mic (cached after first call)
      if (!mediaStream) {
        mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true })
      }

      // 2. Create audio element (cached after first call)
      if (!audioElement) {
        audioElement = document.createElement('audio')
        audioElement.autoplay = true
      }

      // 3. Build the WebRTC transport with pre-injected media
      const transport = new OpenAIRealtimeWebRTC({
        mediaStream,
        audioElement
      })

      // 4. Build the agent with current page text and optional outline
      const agent = buildRealtimeAgent({
        bookId,
        pageText: ctx.pageText,
        outline: ctx.outline,
        onEndConversation: () => listeners.onEndedByAgent?.()
      })

      // 5. Create the session
      // apiKey is supplied at connect() time via the ephemeral key; the constructor
      // arg is required by the type but ignored when connect() provides one.
      const newSession = new RealtimeSession(agent, { transport, apiKey: '' })

      // 6. Wire status events (forwarded to chat-status listener)
      const status = (next: 'idle' | 'connecting' | 'thinking' | 'speaking') =>
        listeners.onChatStatusChange?.(next)

      const onAgentStart = () => {
        if (!hasFiredReadyChime) {
          hasFiredReadyChime = true
          playReadyChime()
        }
        status('thinking')
      }
      const onAudioStart = () => {
        isAgentSpeaking = true
        status('speaking')
      }
      const onAudioStopped = () => {
        isAgentSpeaking = false
        status('idle')
      }
      const onAgentEnd = () => {
        // Only transition to idle if audio isn't currently playing
        // (audio_start may follow agent_end with a small lag)
        if (!isAgentSpeaking) status('idle')
      }
      const onToolStart = () => startThinkingSound()
      const onToolEnd = () => stopThinkingSound()
      const onError = (err: unknown) => {
        captureError(err, { operation: 'voiceChatService', step: 'session_error' })
        stopThinkingSound()
        voiceChatService.dispose()
      }

      newSession.on('agent_start', onAgentStart)
      newSession.on('audio_start', onAudioStart)
      newSession.on('audio_stopped', onAudioStopped)
      newSession.on('agent_end', onAgentEnd)
      newSession.on('agent_tool_start', onToolStart)
      newSession.on('agent_tool_end', onToolEnd)
      newSession.on('error', onError)

      // Teardown closure: removes all listeners on dispose
      sessionCleanup = () => {
        newSession.off('agent_start', onAgentStart)
        newSession.off('audio_start', onAudioStart)
        newSession.off('audio_stopped', onAudioStopped)
        newSession.off('agent_end', onAgentEnd)
        newSession.off('agent_tool_start', onToolStart)
        newSession.off('agent_tool_end', onToolEnd)
        newSession.off('error', onError)
      }

      // 7. Fetch ephemeral key + connect
      const apiKey = await getOrFetchKey()
      await newSession.connect({ apiKey })

      session = newSession
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      setState('active')
      listeners.onChatStatusChange?.('idle')
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
      setState('idle')
      listeners.onChatStatusChange?.('idle')
      throw err
    }
  },

  deactivate() {
    if (state !== 'active' || !session) return
    try {
      session.interrupt()
      session.mute(true)
      if (audioElement) audioElement.muted = true
      setState('paused')
      listeners.onChatStatusChange?.('idle')
      scheduleIdleTimer()
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'deactivate' })
      // We can't trust the session is actually muted — full dispose is safer
      // than leaving a hot mic with the service in a 'paused' state.
      this.dispose()
    }
  },

  dispose() {
    clearIdleTimer()
    if (sessionCleanup) {
      sessionCleanup()
      sessionCleanup = null
    }
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
    if (audioElement) {
      audioElement.pause()
      audioElement.srcObject = null
      audioElement = null
    }
    setState('idle')
    listeners.onChatStatusChange?.('idle')
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
  },

  // --- test hooks ---
  _resetForTests() {
    clearIdleTimer()
    session = null
    sessionCleanup = null
    currentBookId = null
    mediaStream = null
    audioElement = null
    listeners = {}
    state = 'idle'
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
  },
  // Bypasses setState() intentionally — test setup should not fire onStateChange listeners
  _setSessionForTests(fakeSession: RealtimeSession, bookId: number) {
    session = fakeSession
    currentBookId = bookId
    state = 'active'
  }
}
