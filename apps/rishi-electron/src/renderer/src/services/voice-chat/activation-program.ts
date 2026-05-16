import type { Fiber } from 'effect'
import { Effect, Ref, Duration, Cause, Exit } from 'effect'
import {
  MicDeniedError,
  AuthFailedError,
  ConnectTimeoutError,
  ConnectFailedError,
  SessionError,
  toPublicError,
  type ActivationError
} from './errors'
import type {
  AudioElementLike,
  ChatStatus,
  MediaStreamLike,
  RealtimeSessionLike,
  VoiceChatContext,
  VoiceChatServiceDeps
} from './types'

// --- Sync Ref helpers (lesson #1) ---
// Ref.unsafeGet / Ref.unsafeUpdate are NOT runtime exports in effect@3.21.2.
// Only Ref.unsafeMake is callable. Use these wrappers everywhere sync access
// is needed (service.ts's getState/getError contract is synchronous).
const refGet = <A>(r: Ref.Ref<A>): A => Effect.runSync(Ref.get(r))
const refSet = <A>(r: Ref.Ref<A>, v: A): void => Effect.runSync(Ref.set(r, v))
const refUpd = <A>(r: Ref.Ref<A>, f: (a: A) => A): void => Effect.runSync(Ref.update(r, f))

// Re-export the helpers under a void-suppressing reference so TS doesn't
// complain about unused helpers in this file. They are part of the intended
// API surface for future intra-program state needs (see plan lesson #1).
void refGet
void refSet
void refUpd

/**
 * Bundle returned by the activation program on success. `service.ts` stores
 * these on its closure-scoped slots and wires the `'error'` event handler
 * itself (xstate-land — see spec § "xstate / Effect interaction").
 *
 * Calling `cleanup()` detaches the 6 chat-status listeners. The mic stream,
 * audio element, and session itself are released by the program's Scope on
 * fiber interrupt; on success they are owned by service.ts.
 */
export interface SessionHandle {
  readonly session: RealtimeSessionLike
  readonly mediaStream: MediaStreamLike
  readonly audioElement: AudioElementLike
  readonly cleanup: () => void
}

export interface ActivationDeps {
  readonly deps: VoiceChatServiceDeps
  readonly emit: {
    chatStatus: (status: ChatStatus) => void
    endedByAgent: (reason: string) => void
  }
  /** Plain-TS facade over Cache.make — see key-cache.ts (Task 4). */
  readonly keyCacheGet: () => Promise<string>
}

export interface ActivationProgram {
  /**
   * Run the cold-path activation pipeline. Returns a Promise that resolves
   * with a SessionHandle on success, or rejects with one of:
   *   - A plain Error (mapped from a tagged ActivationError via toPublicError)
   *   - A "synthetic interrupt" Error when the activation was superseded by
   *     a subsequent activate() call (service.ts detects this via
   *     isInterruptCause and silently absorbs it).
   *
   * The caller is responsible for installing the session 'error' handler
   * AFTER this Promise resolves — the program only wires the 6 chat-status
   * listeners (agent_start, audio_start, audio_stopped, agent_end,
   * agent_tool_start, agent_tool_end).
   */
  activate(input: { bookId: number; ctx: VoiceChatContext }): {
    promise: Promise<SessionHandle>
    fiber: Fiber.RuntimeFiber<SessionHandle, ActivationError>
  }
}

/** True iff a thrown value came from Effect interpreting an interrupt cause. */
export function isInterruptCause(err: unknown): boolean {
  if (err instanceof Error && err.message === '__VOICE_CHAT_INTERRUPTED__') return true
  // Belt-and-braces for unwrapped FiberFailure cases.
  if (typeof err === 'object' && err !== null && 'cause' in err) {
    const c = err.cause
    if (Cause.isCause(c) && Cause.isInterruptedOnly(c)) return true
  }
  return false
}

function mapMicError(e: unknown): MicDeniedError {
  const name = (e as { name?: string }).name
  const message = (e as { message?: string }).message ?? String(e)
  if (name === 'NotAllowedError' || name === 'NotFoundError') {
    return new MicDeniedError({ name, message })
  }
  return new MicDeniedError({ name: 'Unknown', message })
}

function msgOf(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}

interface BuiltSession {
  session: RealtimeSessionLike
  cleanup: () => void
}

export function makeActivationProgram(a: ActivationDeps): ActivationProgram {
  const { deps, emit, keyCacheGet } = a

  function buildSession(
    bookId: number,
    ctx: VoiceChatContext,
    mediaStream: MediaStreamLike,
    audioElement: AudioElementLike
  ): BuiltSession {
    const transport = deps.webrtcFactory({ mediaStream, audioElement })
    const agent = deps.agentFactory({
      bookId,
      pageText: ctx.pageText,
      outline: ctx.outline,
      activeParagraphText: ctx.activeParagraphText,
      onEndConversation: (reason) => emit.endedByAgent(reason),
      rag: deps.rag,
      language: deps.getLanguage()
    })
    const session = deps.sessionFactory(agent, { transport, apiKey: '' })

    let hasFiredReadyChime = false
    let isAgentSpeaking = false

    const onAgentStart = (): void => {
      if (!hasFiredReadyChime) {
        hasFiredReadyChime = true
        deps.effects.playReadyChime()
      }
      emit.chatStatus('thinking')
    }
    const onAudioStart = (): void => {
      isAgentSpeaking = true
      emit.chatStatus('speaking')
    }
    const onAudioStopped = (): void => {
      isAgentSpeaking = false
      emit.chatStatus('idle')
    }
    const onAgentEnd = (): void => {
      if (!isAgentSpeaking) emit.chatStatus('idle')
    }
    const onToolStart = (): void => {
      deps.effects.startThinkingSound()
      // Emit thinking on tool entry so consumers see the agent is working
      // and so the service's inactivity timer resets — a tool call > the
      // inactivity timeout (e.g. slow RAG) must not auto-close the session.
      emit.chatStatus('thinking')
    }
    const onToolEnd = (): void => {
      deps.effects.stopThinkingSound()
      // Stay in 'thinking' on tool completion — the agent may call another
      // tool or about to speak. The next audio_start / agent_end will move
      // status forward. This emit primarily exists to reset the inactivity
      // timer so a back-to-back chain of tools doesn't accumulate timeout.
      emit.chatStatus('thinking')
    }

    const listeners: Array<readonly [string, (...args: unknown[]) => void]> = [
      ['agent_start', onAgentStart],
      ['audio_start', onAudioStart],
      ['audio_stopped', onAudioStopped],
      ['agent_end', onAgentEnd],
      ['agent_tool_start', onToolStart],
      ['agent_tool_end', onToolEnd]
    ]
    for (const [evt, fn] of listeners) session.on(evt, fn)
    const cleanup = (): void => {
      for (const [evt, fn] of listeners) session.off(evt, fn)
    }

    return { session, cleanup }
  }

  const activationPipeline = (
    bookId: number,
    ctx: VoiceChatContext
  ): Effect.Effect<SessionHandle, ActivationError> => {
    // We use Effect.scoped so finalizers run on failure/interrupt. On success
    // the activation returns a SessionHandle and we DETACH the inner finalizers
    // by tracking acquired resources in local vars and using `Effect.acquireRelease`
    // semantics inverted: finalizer = "release iff not yet consumed".
    let success = false

    return Effect.scoped(
      Effect.gen(function* () {
        // mic. Echo cancellation + noise suppression prevent TTS playback
        // bleed from being captured by the mic and re-sent through realtime
        // as billable audio input.
        const mediaStream = yield* Effect.acquireRelease(
          Effect.tryPromise({
            try: () =>
              deps.media.getUserMedia({
                audio: {
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true
                }
              }),
            catch: (e) => mapMicError(e)
          }),
          (s) =>
            Effect.sync(() => {
              if (!success) s.getTracks().forEach((t) => t.stop())
            })
        )

        // audio el
        const audioElement = yield* Effect.acquireRelease(
          Effect.sync(() => deps.media.createAudioElement()),
          (el) =>
            Effect.sync(() => {
              if (!success) {
                el.pause()
                el.srcObject = null
              }
            })
        )

        // session
        const built = yield* Effect.acquireRelease(
          Effect.sync(() => buildSession(bookId, ctx, mediaStream, audioElement)),
          (h) =>
            Effect.sync(() => {
              if (!success) {
                h.cleanup()
                try {
                  h.session.close()
                } catch {
                  /* best-effort */
                }
              }
            })
        )

        // key
        const apiKey = yield* Effect.tryPromise({
          try: () => keyCacheGet(),
          catch: (e) => new AuthFailedError({ message: msgOf(e) })
        })

        // connect with timeout
        yield* Effect.tryPromise({
          try: () => built.session.connect({ apiKey }),
          catch: (e) => new ConnectFailedError({ message: msgOf(e) })
        }).pipe(
          Effect.timeoutFail({
            duration: Duration.millis(deps.config.connectTimeoutMs),
            onTimeout: () => new ConnectTimeoutError({ ms: deps.config.connectTimeoutMs })
          })
        )

        // unmute
        yield* Effect.sync(() => {
          built.session.mute(false)
          audioElement.muted = false
        })

        // Mark success so finalizers above become no-ops.
        success = true

        return {
          session: built.session,
          mediaStream,
          audioElement,
          cleanup: built.cleanup
        } satisfies SessionHandle
      })
    )
  }

  return {
    activate({ bookId, ctx }) {
      const fiber = Effect.runFork(activationPipeline(bookId, ctx))
      const promise = new Promise<SessionHandle>((resolve, reject) => {
        fiber.addObserver((exit) => {
          if (Exit.isSuccess(exit)) {
            resolve(exit.value)
            return
          }
          // exit is Exit.Failure
          const cause = exit.cause
          if (Cause.isInterruptedOnly(cause)) {
            // Superseded — surface a marker the service layer can recognize.
            reject(new Error('__VOICE_CHAT_INTERRUPTED__'))
            return
          }
          // Find the first tagged error; map to plain Error via toPublicError.
          const failures = Array.from(Cause.failures(cause))
          const first = failures.length > 0 ? failures[0] : null
          if (first) {
            reject(toPublicError(first))
            return
          }
          // Defect — surface a generic ConnectFailedError-mapped Error.
          reject(new Error(Cause.pretty(cause)))
        })
      })
      return { promise, fiber }
    }
  }
}

// Silence unused-export warning for SessionError — re-exported by errors.ts.
void SessionError
