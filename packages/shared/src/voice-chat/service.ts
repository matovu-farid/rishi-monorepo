import { Effect, Fiber } from 'effect'
import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import { makeActivationProgram, isInterruptCause, type SessionHandle } from './activation-program'
import type { ActivationError } from './errors'
import type {
  AudioElementLike,
  ChatStatus,
  ClockPort,
  LocalVoiceVad,
  MediaStreamLike,
  RealtimeSessionLike,
  VoiceChatContext,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceError,
  VoiceErrorReason
} from './types'

/**
 * Voice-chat service factory. Verbatim port from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`.
 *
 * Only difference: electron's `captureError` import is replaced by an
 * optional `captureError` port on `VoiceChatServiceDeps` (defaults to
 * no-op). The mobile-side service supplies a Sentry-React-Native wrapper.
 */

function classifyError(err: unknown): VoiceErrorReason {
  if (err instanceof OfflineError) return 'connect_failed'
  const name = (err as { name?: string }).name
  const message = (err as { message?: string }).message ?? ''
  if (name === 'NotAllowedError' || name === 'NotFoundError') return 'mic_denied'
  if (message.includes('Not authenticated') || message.includes('auth')) return 'auth_failed'
  if (message.includes('timed out')) return 'timeout'
  return 'connect_failed'
}

function fingerprintContext(ctx: VoiceChatContext): string {
  // Note: activeParagraphText is intentionally excluded. It changes on every
  // TTS paragraph advance; including it forced session.updateAgent to re-upload
  // the full instructions block as input tokens once per paragraph.
  return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
}

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const { rag, connectivity, ipc, agentFactory, effects, clock, config, getLanguage } = deps
  const capture = deps.captureError ?? (() => undefined)

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  const actor = createActor(voiceChatMachine)
  actor.start()
  let lastPublicState: VoiceChatPublicState = actor.getSnapshot().value
  actor.subscribe(() => {
    const next = actor.getSnapshot().value
    if (next === lastPublicState) return
    lastPublicState = next
    stateEmitter.emit(next)
  })

  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeClientSecret(getLanguage()),
    ttlMs: config.keyTtlMs,
    clock
  })

  const program = makeActivationProgram({
    deps,
    emit: {
      chatStatus: (s) => emitChatStatus(s),
      endedByAgent: (r) => endedByAgentEmitter.emit(r)
    },
    keyCacheGet: () => keyCache.get()
  })

  // Session-scoped state, in closure.
  let session: RealtimeSessionLike | null = null
  let sessionCleanup: (() => void) | null = null
  let currentBookId: number | null = null
  let mediaStream: MediaStreamLike | null = null
  let audioElement: AudioElementLike | null = null
  let vad: LocalVoiceVad | null = null
  let lastContextFingerprint: string | null = null
  let currentFiber: Fiber.RuntimeFiber<SessionHandle, ActivationError> | null = null
  let inactivityTimer: ReturnType<ClockPort['setTimeout']> | null = null
  let connectivityUnsub: (() => void) | null = null
  let started = false

  function clearInactivityTimer() {
    if (inactivityTimer !== null) {
      clock.clearTimeout(inactivityTimer)
      inactivityTimer = null
    }
  }

  function scheduleInactivityTimer() {
    clearInactivityTimer()
    inactivityTimer = clock.setTimeout(() => {
      endedByAgentEmitter.emit('inactivity_timeout')
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }, config.inactivityTimeoutMs)
  }

  function emitChatStatus(s: ChatStatus): void {
    if (session) scheduleInactivityTimer()
    chatStatusEmitter.emit(s)
  }

  function disposeInternal() {
    clearInactivityTimer()
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
        capture(err, { operation: 'voiceChatService', step: 'dispose_close' })
      }
    }
    if (vad) {
      try {
        vad.dispose()
      } catch (err) {
        capture(err, { operation: 'voiceChatService', step: 'dispose_vad' })
      }
      vad = null
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
    lastContextFingerprint = null
  }

  function onSessionError(err: unknown) {
    capture(err, { operation: 'voiceChatService', step: 'session_error' })
    effects.stopThinkingSound()
    actor.send({
      type: 'SESSION_ERROR',
      reason: 'session_error',
      message: err instanceof Error ? err.message : undefined
    })
    disposeInternal()
    actor.send({ type: 'DISPOSE' })
  }

  async function doActivate(bookId: number, ctx: VoiceChatContext): Promise<void> {
    if (session && currentBookId !== null && currentBookId !== bookId) {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }

    if (session && currentBookId === bookId) {
      actor.send({ type: 'CONNECT_STARTED' })
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const liveSession = session
          const newAgent = agentFactory({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            activeParagraphText: ctx.activeParagraphText,
            visualSummary: ctx.visualSummary,
            onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
            onInspectImage: (image) =>
              liveSession.addImage(image.dataUrl, { triggerResponse: false }),
            rag,
            language: getLanguage()
          })
          await session.updateAgent(newAgent)
          // eslint-disable-next-line require-atomic-updates
          lastContextFingerprint = fp
        }
        session.mute(false)
        if (audioElement) audioElement.muted = false
        actor.send({ type: 'CONNECT_SUCCEEDED' })
        emitChatStatus('idle')
      } catch (err) {
        capture(err, { operation: 'voiceChatService', step: 'activate_warm' })
        actor.send({
          type: 'CONNECT_FAILED',
          reason: classifyError(err),
          message: err instanceof Error ? err.message : undefined
        })
        throw err
      }
      return
    }

    if (currentFiber) {
      await Effect.runPromise(Fiber.interrupt(currentFiber))
    }

    actor.send({ type: 'CONNECT_STARTED' })
    chatStatusEmitter.emit('connecting')

    const { promise, fiber } = program.activate({ bookId, ctx })
    // eslint-disable-next-line require-atomic-updates
    currentFiber = fiber

    try {
      const handle = await promise

      /* eslint-disable require-atomic-updates */
      session = handle.session
      mediaStream = handle.mediaStream
      audioElement = handle.audioElement
      vad = handle.vad
      sessionCleanup = handle.cleanup
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      /* eslint-enable require-atomic-updates */

      session.on('error', onSessionError)

      actor.send({ type: 'CONNECT_SUCCEEDED' })
      emitChatStatus('idle')
    } catch (err) {
      if (isInterruptCause(err)) return

      capture(err, { operation: 'voiceChatService', step: 'activate_cold' })
      actor.send({
        type: 'CONNECT_FAILED',
        reason: classifyError(err),
        message: err instanceof Error ? err.message : undefined
      })
      chatStatusEmitter.emit('idle')
      throw err
    } finally {
      if (currentFiber === fiber) currentFiber = null
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
      if (currentFiber) {
        Effect.runFork(Fiber.interrupt(currentFiber))
        currentFiber = null
      }
      disposeInternal()
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
    },

    async activate(bookId, ctx) {
      if (!connectivity.isOnline()) {
        actor.send({ type: 'OFFLINE' })
        throw new OfflineError()
      }
      await doActivate(bookId, ctx)
    },

    preconnect(_bookId, _ctx) {
      void _bookId
      void _ctx
      try {
        deps.network.preconnectOpenAI()
      } catch (err) {
        capture(err, { operation: 'voiceChatService', step: 'preconnect_network' })
      }
      void keyCache.get().catch((err: unknown) => {
        capture(err, { operation: 'voiceChatService', step: 'preconnect_key_prefetch' })
      })
      return Promise.resolve()
    },

    deactivate() {
      const value = actor.getSnapshot().value
      if (value === 'idle' || value === 'offline' || value === 'error') return
      if (currentFiber) {
        Effect.runFork(Fiber.interrupt(currentFiber))
        currentFiber = null
      }
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    },

    dispose() {
      if (currentFiber) {
        Effect.runFork(Fiber.interrupt(currentFiber))
        currentFiber = null
      }
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    },

    prewarmKey() {
      void keyCache.get()
    },

    invalidateKey() {
      keyCache.invalidate()
    },

    getState() {
      return actor.getSnapshot().value
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
