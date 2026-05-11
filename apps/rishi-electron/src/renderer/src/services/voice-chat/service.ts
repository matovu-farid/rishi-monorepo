import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import { captureError } from '@/utils/sentry'
import type {
  AudioElementLike,
  ChatStatus,
  ClockPort,
  MediaStreamLike,
  RealtimeSessionLike,
  VoiceChatContext,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceError,
  VoiceErrorReason
} from './types'

function classifyError(err: unknown): VoiceErrorReason {
  if (err instanceof OfflineError) return 'connect_failed'
  const name = (err as { name?: string })?.name
  const message = (err as { message?: string })?.message ?? ''
  if (name === 'NotAllowedError' || name === 'NotFoundError') return 'mic_denied'
  if (message.includes('Not authenticated') || message.includes('auth')) return 'auth_failed'
  if (message.includes('timed out')) return 'timeout'
  return 'connect_failed'
}

function fingerprintContext(ctx: VoiceChatContext): string {
  return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
}

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const {
    rag,
    connectivity,
    ipc,
    webrtcFactory,
    agentFactory,
    sessionFactory,
    media,
    effects,
    clock,
    config
  } = deps

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  const actor = createActor(voiceChatMachine)
  actor.start()
  let lastPublicState: VoiceChatPublicState = actor.getSnapshot().value as VoiceChatPublicState
  actor.subscribe(() => {
    const next = actor.getSnapshot().value as VoiceChatPublicState
    if (next === lastPublicState) return
    lastPublicState = next
    stateEmitter.emit(next)
  })

  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeClientSecret(),
    ttlMs: config.keyTtlMs,
    clock
  })

  // Session-scoped state, in closure (not module).
  let session: RealtimeSessionLike | null = null
  let sessionCleanup: (() => void) | null = null
  let currentBookId: number | null = null
  let idleTimer: ReturnType<ClockPort['setTimeout']> | null = null
  let mediaStream: MediaStreamLike | null = null
  let audioElement: AudioElementLike | null = null
  let lastContextFingerprint: string | null = null
  let hasUsedVoiceInSession = false
  let activateInFlight: Promise<void> | null = null
  let activateGeneration = 0
  let preconnectIntent = false
  let hasFiredReadyChime = false
  let isAgentSpeaking = false
  let connectivityUnsub: (() => void) | null = null
  let started = false

  function clearIdleTimer() {
    if (idleTimer !== null) {
      clock.clearTimeout(idleTimer)
      idleTimer = null
    }
  }

  function scheduleIdleTimer() {
    clearIdleTimer()
    idleTimer = clock.setTimeout(() => {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }, config.idleTimeoutMs)
  }

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
    chatStatusEmitter.emit('idle')
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
  }

  async function doActivate(
    bookId: number,
    ctx: VoiceChatContext,
    gen: number
  ): Promise<void> {
    clearIdleTimer()

    // Different bookId — dispose existing session first.
    if (session && currentBookId !== null && currentBookId !== bookId) {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }

    // Warm path: same bookId, session still alive.
    if (session && currentBookId === bookId) {
      actor.send({ type: 'CONNECT_STARTED' })
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const newAgent = agentFactory({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
            rag
          })
          await session.updateAgent(newAgent)
          if (gen !== activateGeneration) return
          lastContextFingerprint = fp
        }
        session.mute(false)
        if (audioElement) audioElement.muted = false
        if (gen !== activateGeneration) return
        actor.send({ type: 'CONNECT_SUCCEEDED' })
        chatStatusEmitter.emit('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        if (gen === activateGeneration) {
          actor.send({
            type: 'CONNECT_FAILED',
            reason: classifyError(err),
            message: err instanceof Error ? err.message : undefined
          })
        }
        throw err
      }
      return
    }

    // Cold path.
    actor.send({ type: 'CONNECT_STARTED' })
    chatStatusEmitter.emit('connecting')

    let newSession: RealtimeSessionLike | null = null
    try {
      if (!mediaStream) {
        mediaStream = await media.getUserMedia({ audio: true })
      }
      if (!audioElement) {
        audioElement = media.createAudioElement()
      }
      const transport = webrtcFactory({ mediaStream, audioElement })
      const agent = agentFactory({
        bookId,
        pageText: ctx.pageText,
        outline: ctx.outline,
        onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
        rag
      })
      newSession = sessionFactory(agent, { transport, apiKey: '' })

      const status = (s: ChatStatus) => chatStatusEmitter.emit(s)
      const onAgentStart = () => {
        if (!hasFiredReadyChime) {
          hasFiredReadyChime = true
          effects.playReadyChime()
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
        if (!isAgentSpeaking) status('idle')
      }
      const onToolStart = () => effects.startThinkingSound()
      const onToolEnd = () => effects.stopThinkingSound()
      const onError = (err: unknown) => {
        captureError(err, { operation: 'voiceChatService', step: 'session_error' })
        effects.stopThinkingSound()
        actor.send({
          type: 'SESSION_ERROR',
          reason: 'session_error',
          message: err instanceof Error ? err.message : undefined
        })
        disposeInternal()
        actor.send({ type: 'DISPOSE' })
      }
      newSession.on('agent_start', onAgentStart)
      newSession.on('audio_start', onAudioStart)
      newSession.on('audio_stopped', onAudioStopped)
      newSession.on('agent_end', onAgentEnd)
      newSession.on('agent_tool_start', onToolStart)
      newSession.on('agent_tool_end', onToolEnd)
      newSession.on('error', onError)

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

      const apiKey = await keyCache.get()

      // Connect with timeout race.
      let connectTimeout: ReturnType<ClockPort['setTimeout']> | null = null
      try {
        await Promise.race([
          newSession.connect({ apiKey }),
          new Promise<never>((_, reject) => {
            connectTimeout = clock.setTimeout(() => {
              reject(
                new Error(
                  `Realtime session connect timed out after ${config.connectTimeoutMs / 1000}s`
                )
              )
            }, config.connectTimeoutMs)
          })
        ])
      } finally {
        if (connectTimeout !== null) clock.clearTimeout(connectTimeout)
      }

      if (gen !== activateGeneration) {
        // Stale activation — tear down half-built session and bail without
        // emitting CONNECT_SUCCEEDED.
        if (sessionCleanup) sessionCleanup()
        sessionCleanup = null
        try {
          newSession.close()
        } catch {
          /* best effort */
        }
        return
      }

      session = newSession
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      actor.send({ type: 'CONNECT_SUCCEEDED' })
      chatStatusEmitter.emit('idle')
      hasUsedVoiceInSession = true
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
      if (sessionCleanup) {
        sessionCleanup()
        sessionCleanup = null
      }
      if (newSession) {
        try {
          newSession.close()
        } catch {
          /* best effort */
        }
      }
      if (gen === activateGeneration) {
        actor.send({
          type: 'CONNECT_FAILED',
          reason: classifyError(err),
          message: err instanceof Error ? err.message : undefined
        })
        chatStatusEmitter.emit('idle')
      }
      throw err
    }
  }

  const svc: VoiceChatService = {
    start() {
      if (started) return
      started = true
      connectivityUnsub = connectivity.subscribe((online) => {
        if (!online) {
          if (session) disposeInternal()
          actor.send({ type: 'OFFLINE' })
        } else if (actor.getSnapshot().value === 'offline') {
          actor.send({ type: 'ONLINE' })
        }
      })
    },

    stop() {
      if (!started) return
      started = false
      disposeInternal()
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
      activateGeneration++
    },

    async activate(bookId, ctx) {
      if (!connectivity.isOnline()) {
        actor.send({ type: 'OFFLINE' })
        throw new OfflineError()
      }
      preconnectIntent = false
      activateGeneration++
      const gen = activateGeneration
      if (activateInFlight) return activateInFlight
      activateInFlight = doActivate(bookId, ctx, gen)
      try {
        await activateInFlight
      } finally {
        activateInFlight = null
      }
    },

    async preconnect(bookId, ctx) {
      if (!hasUsedVoiceInSession) return
      if (!connectivity.isOnline()) return
      if (session && currentBookId === bookId) return
      if (activateInFlight) return
      preconnectIntent = true
      try {
        await svc.activate(bookId, ctx)
        if (preconnectIntent && session) {
          // Cast to RealtimeSessionLike for closure-scoped narrowing.
          const s: RealtimeSessionLike = session
          s.interrupt()
          s.mute(true)
          if (audioElement) audioElement.muted = true
          actor.send({ type: 'DEACTIVATE' })
        }
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'preconnect' })
      } finally {
        preconnectIntent = false
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
        chatStatusEmitter.emit('idle')
        scheduleIdleTimer()
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'deactivate' })
        disposeInternal()
        actor.send({ type: 'DISPOSE' })
      }
    },

    dispose() {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    },

    prewarmKey() {
      void keyCache.get()
    },

    getState() {
      return actor.getSnapshot().value as VoiceChatPublicState
    },

    getError(): VoiceError | null {
      return actor.getSnapshot().context.error
    },

    dismissError() {
      actor.send({ type: 'DISMISS_ERROR' })
    },

    onStateChange: stateEmitter.on,
    onChatStatus: chatStatusEmitter.on,
    onEndedByAgent: endedByAgentEmitter.on
  }

  return svc
}
