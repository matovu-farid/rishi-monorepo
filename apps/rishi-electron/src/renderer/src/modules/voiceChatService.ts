import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import { createActor } from 'xstate'
import { getOrFetchKey, prefetchRealtimeKey } from './realtime'
import { buildRealtimeAgent } from './buildRealtimeAgent'
import { captureError } from '@/utils/sentry'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
import type { BookOutline } from '@/lib/api'
import {
  voiceChatMachine,
  type VoiceChatStateValue,
  type VoiceErrorReason
} from '@/machines/voiceChatMachine'
import { getConnectivityService } from '@/services'

export type VoiceChatState = VoiceChatStateValue

export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
}

export interface VoiceChatEvents {
  onStateChange: (state: VoiceChatState) => void
  onChatStatusChange: (status: 'idle' | 'connecting' | 'thinking' | 'speaking') => void
  onEndedByAgent: () => void
}

export class OfflineError extends Error {
  constructor() {
    super('You are offline. Voice chat is unavailable until you reconnect.')
    this.name = 'OfflineError'
  }
}

const IDLE_TIMEOUT_MS = 15 * 60 * 1000
const CONNECT_TIMEOUT_MS = 60 * 1000

// Module-level singleton actor — the source of truth for voice chat state.
const actor = createActor(voiceChatMachine)
actor.start()

// Module-level singleton state (effects + caches)
let hasFiredReadyChime = false
let isAgentSpeaking = false
let session: RealtimeSession | null = null
let sessionCleanup: (() => void) | null = null
let currentBookId: number | null = null
let idleTimer: ReturnType<typeof setTimeout> | null = null
let mediaStream: MediaStream | null = null
let audioElement: HTMLAudioElement | null = null
let listeners: Partial<VoiceChatEvents> = {}
let lastContextFingerprint: string | null = null
let hasUsedVoiceInSession = false
let activateInFlight: Promise<void> | null = null
let preconnectIntent = false

// Fire onStateChange whenever the machine transitions
actor.subscribe((snapshot) => {
  listeners.onStateChange?.(snapshot.value as VoiceChatState)
})

// Reflect connectivity into the voice machine. When network drops mid-session
// we tear the session down and surface 'offline' to the UI.
getConnectivityService().subscribe((online) => {
  if (!online) {
    if (session) {
      disposeInternal()
    }
    actor.send({ type: 'OFFLINE' })
  } else if (actor.getSnapshot().value === 'offline') {
    actor.send({ type: 'ONLINE' })
  }
})

function classifyActivateError(err: unknown): VoiceErrorReason {
  if (err instanceof OfflineError) return 'connect_failed'
  const name = (err as { name?: string })?.name
  const message = (err as { message?: string })?.message ?? ''
  if (name === 'NotAllowedError' || name === 'NotFoundError') return 'mic_denied'
  if (message.includes('Not authenticated') || message.includes('auth')) return 'auth_failed'
  if (message.includes('timed out')) return 'timeout'
  return 'connect_failed'
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

// Internal dispose used by connectivity handler — separated to avoid recursion
// (dispose() sends DISPOSE which would re-enter the connectivity check otherwise).
function disposeInternal() {
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
  listeners.onChatStatusChange?.('idle')
  hasFiredReadyChime = false
  isAgentSpeaking = false
  lastContextFingerprint = null
}

export const voiceChatService = {
  /** xstate actor — subscribe with actor.subscribe() or useSelector(). */
  actor,

  getState(): VoiceChatState {
    return actor.getSnapshot().value as VoiceChatState
  },

  getError() {
    return actor.getSnapshot().context.error
  },

  dismissError() {
    actor.send({ type: 'DISMISS_ERROR' })
  },

  setListeners(next: Partial<VoiceChatEvents>) {
    listeners = { ...listeners, ...next }
  },

  /** Prefetch the OpenAI ephemeral key — safe to call on book open. Does NOT prompt for mic. */
  prewarmKey() {
    prefetchRealtimeKey()
  },

  /**
   * Pre-warm the WebRTC connection in the background after the user has used voice chat
   * at least once this session. Saves ~600-1500ms on first activation in subsequent books.
   * No-op if the user hasn't used voice yet — we don't want to burn the WebRTC handshake
   * for users who never use voice. No-op if offline.
   */
  async preconnect(bookId: number, ctx: VoiceChatContext): Promise<void> {
    if (!hasUsedVoiceInSession) return
    if (!getConnectivityService().isOnline()) return
    if (session && currentBookId === bookId) return
    if (activateInFlight) return
    preconnectIntent = true
    try {
      await this.activate(bookId, ctx, { fromPreconnect: true })
      // Only mute if the user did NOT click during our activate.
      // If preconnectIntent was cleared (by a user-initiated activate),
      // skip the mute so the user sees 'active' as they expect.
      if (preconnectIntent && session) {
        session.interrupt()
        session.mute(true)
        if (audioElement) audioElement.muted = true
        actor.send({ type: 'DEACTIVATE' })
      }
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'preconnect' })
    } finally {
      preconnectIntent = false
    }
  },

  /**
   * Start or resume voice chat for the given book.
   * - First call: full setup (mic prompt + WebRTC handshake + agent build).
   * - Subsequent call on same book: updateAgent + unmute (near-instant).
   * - Call on different book: dispose old session, then full setup for new book.
   * Throws OfflineError synchronously if offline.
   */
  async activate(
    bookId: number,
    ctx: VoiceChatContext,
    opts: { fromPreconnect?: boolean } = {}
  ): Promise<void> {
    if (!getConnectivityService().isOnline()) {
      actor.send({ type: 'OFFLINE' })
      throw new OfflineError()
    }
    if (!opts.fromPreconnect) {
      preconnectIntent = false
    }
    if (activateInFlight) {
      return activateInFlight
    }
    activateInFlight = this._doActivate(bookId, ctx)
    try {
      await activateInFlight
    } finally {
      activateInFlight = null
    }
  },

  async _doActivate(bookId: number, ctx: VoiceChatContext): Promise<void> {
    clearIdleTimer()

    // Book switched while a session is alive — fully dispose first
    if (session && currentBookId !== null && currentBookId !== bookId) {
      this.dispose()
    }

    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text (if changed), then unmute
      actor.send({ type: 'CONNECT_STARTED' })
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
        actor.send({ type: 'CONNECT_SUCCEEDED' })
        listeners.onChatStatusChange?.('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        actor.send({
          type: 'CONNECT_FAILED',
          reason: classifyActivateError(err),
          message: err instanceof Error ? err.message : undefined
        })
        throw err
      }
      return
    }

    // Cold path: first-time activation or after dispose
    actor.send({ type: 'CONNECT_STARTED' })
    listeners.onChatStatusChange?.('connecting')

    let newSession: RealtimeSession | null = null
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
      newSession = new RealtimeSession(agent, { transport, apiKey: '' })

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
        actor.send({
          type: 'SESSION_ERROR',
          reason: 'session_error',
          message: err instanceof Error ? err.message : undefined
        })
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
      const s = newSession
      sessionCleanup = () => {
        s.off('agent_start', onAgentStart)
        s.off('audio_start', onAudioStart)
        s.off('audio_stopped', onAudioStopped)
        s.off('agent_end', onAgentEnd)
        s.off('agent_tool_start', onToolStart)
        s.off('agent_tool_end', onToolEnd)
        s.off('error', onError)
      }

      // 7. Fetch ephemeral key + connect (with timeout — WebRTC handshake can
      // stall silently on flaky networks, leaving the panel "open but stuck")
      const apiKey = await getOrFetchKey()
      let connectTimeout: ReturnType<typeof setTimeout> | undefined
      try {
        await Promise.race([
          newSession.connect({ apiKey }),
          new Promise<never>((_, reject) => {
            connectTimeout = setTimeout(
              () =>
                reject(
                  new Error(
                    `Realtime session connect timed out after ${CONNECT_TIMEOUT_MS / 1000}s`
                  )
                ),
              CONNECT_TIMEOUT_MS
            )
          })
        ])
      } finally {
        if (connectTimeout) clearTimeout(connectTimeout)
      }

      session = newSession
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      actor.send({ type: 'CONNECT_SUCCEEDED' })
      listeners.onChatStatusChange?.('idle')
      hasUsedVoiceInSession = true
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
      // Tear down the half-built session so a timed-out connect that finishes
      // in the background can't leave a hot mic + WebRTC pipe running invisibly.
      if (sessionCleanup) {
        sessionCleanup()
        sessionCleanup = null
      }
      if (newSession) {
        try {
          newSession.close()
        } catch {
          // best-effort; already in the error path
        }
      }
      actor.send({
        type: 'CONNECT_FAILED',
        reason: classifyActivateError(err),
        message: err instanceof Error ? err.message : undefined
      })
      listeners.onChatStatusChange?.('idle')
      throw err
    }
  },

  deactivate() {
    const value = actor.getSnapshot().value
    if (value !== 'active' || !session) return
    try {
      session.interrupt()
      session.mute(true)
      if (audioElement) audioElement.muted = true
      actor.send({ type: 'DEACTIVATE' })
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
    disposeInternal()
    actor.send({ type: 'DISPOSE' })
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
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
    hasUsedVoiceInSession = false
    activateInFlight = null
    preconnectIntent = false
    actor.send({ type: 'DISPOSE' })
  },
  _setSessionForTests(fakeSession: RealtimeSession, bookId: number) {
    session = fakeSession
    currentBookId = bookId
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_SUCCEEDED' })
  },
  _hasUsedVoiceInSession() {
    return hasUsedVoiceInSession
  }
}
