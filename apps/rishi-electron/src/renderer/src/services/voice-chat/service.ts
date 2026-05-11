import { Effect, Fiber } from 'effect'
import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import { makeActivationProgram, isInterruptCause, type SessionHandle } from './activation-program'
import { type ActivationError } from './errors'
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
  const { rag, connectivity, ipc, agentFactory, effects, clock, config } = deps

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

  const program = makeActivationProgram({
    deps,
    emit: {
      chatStatus: (s) => chatStatusEmitter.emit(s),
      endedByAgent: (r) => endedByAgentEmitter.emit(r)
    },
    keyCacheGet: () => keyCache.get()
  })

  // Session-scoped state, in closure.
  let session: RealtimeSessionLike | null = null
  let sessionCleanup: (() => void) | null = null
  let currentBookId: number | null = null
  let idleTimer: ReturnType<ClockPort['setTimeout']> | null = null
  let mediaStream: MediaStreamLike | null = null
  let audioElement: AudioElementLike | null = null
  let lastContextFingerprint: string | null = null
  let hasUsedVoiceInSession = false
  let currentFiber: Fiber.RuntimeFiber<SessionHandle, ActivationError> | null = null
  let preconnectIntent = false
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
    lastContextFingerprint = null
  }

  function onSessionError(err: unknown) {
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

  async function doActivate(bookId: number, ctx: VoiceChatContext): Promise<void> {
    clearIdleTimer()

    // Different bookId — dispose existing session first.
    if (session && currentBookId !== null && currentBookId !== bookId) {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }

    // Warm path: same bookId, session still alive. Plain TS — no Effect.
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
          lastContextFingerprint = fp
        }
        session.mute(false)
        if (audioElement) audioElement.muted = false
        actor.send({ type: 'CONNECT_SUCCEEDED' })
        chatStatusEmitter.emit('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        actor.send({
          type: 'CONNECT_FAILED',
          reason: classifyError(err),
          message: err instanceof Error ? err.message : undefined
        })
        throw err
      }
      return
    }

    // Cold path — Effect program.
    if (currentFiber) {
      // Supersede the previous activation. The acquireRelease releases inside
      // the program will tear down any half-built resources automatically.
      await Effect.runPromise(Fiber.interrupt(currentFiber))
    }

    actor.send({ type: 'CONNECT_STARTED' })
    chatStatusEmitter.emit('connecting')

    const { promise, fiber } = program.activate({ bookId, ctx })
    currentFiber = fiber

    try {
      const handle = await promise

      // Hand resources to service.ts's closure.
      session = handle.session
      mediaStream = handle.mediaStream
      audioElement = handle.audioElement
      sessionCleanup = handle.cleanup
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)

      // Wire the session 'error' handler post-resolve (xstate-land, not Effect).
      session.on('error', onSessionError)

      actor.send({ type: 'CONNECT_SUCCEEDED' })
      chatStatusEmitter.emit('idle')
      hasUsedVoiceInSession = true
    } catch (err) {
      // Superseded by a subsequent activate() — silent.
      if (isInterruptCause(err)) return

      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
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
      // Interrupt any in-flight activation, then tear down.
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

    async preconnect(bookId, ctx) {
      if (!hasUsedVoiceInSession) return
      if (!connectivity.isOnline()) return
      if (session && currentBookId === bookId) return
      preconnectIntent = true
      try {
        await svc.activate(bookId, ctx)
        if (preconnectIntent && session) {
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
