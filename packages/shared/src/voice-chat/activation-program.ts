import type { Fiber } from 'effect'
import { Effect, Duration, Cause, Exit } from 'effect'
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
  LocalVoiceVad,
  MediaRecorderLike,
  MediaStreamLike,
  RealtimeSessionLike,
  VoiceChatContext,
  VoiceChatIpc,
  VoiceChatServiceDeps
} from './types'
import { VadDisposedError, VadTimeoutError } from './local-vad'

/**
 * Activation program. Verbatim port from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/activation-program.ts`.
 * Only difference: the electron-side `captureError` from `@/utils/sentry` is
 * threaded through the optional `captureError` port on `VoiceChatServiceDeps`,
 * which defaults to a no-op when callers don't supply one.
 */

/**
 * Bundle returned by the activation program on success. `service.ts` stores
 * these on its closure-scoped slots and wires the `'error'` event handler
 * itself (xstate-land — see spec § "xstate / Effect interaction").
 */
export interface SessionHandle {
  readonly session: RealtimeSessionLike
  readonly mediaStream: MediaStreamLike
  readonly audioElement: AudioElementLike
  readonly cleanup: () => void
  /** Null when AudioContext is unavailable. service.ts disposes alongside the session. */
  readonly vad: LocalVoiceVad | null
}

export interface ActivationDeps {
  readonly deps: VoiceChatServiceDeps
  readonly emit: {
    chatStatus: (status: ChatStatus) => void
    endedByAgent: (reason: string) => void
  }
  /** Plain-TS facade over Cache.make — see key-cache.ts. */
  readonly keyCacheGet: () => Promise<string>
}

export interface ActivationProgram {
  /**
   * Run the cold-path activation pipeline. Returns a Promise that resolves
   * with a SessionHandle on success, or rejects with:
   *   - A plain Error (mapped from a tagged ActivationError via toPublicError)
   *   - A "synthetic interrupt" Error when the activation was superseded by
   *     a subsequent activate() call.
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
    const c = (err as { cause: unknown }).cause
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

/** Captures speech the user uttered during the connect window. */
interface SpeechBuffer {
  recorder: MediaRecorderLike
  /** Rolling buffer of MediaRecorder timeslice chunks. Capped at MAX_SPEECH_BUFFER_CHUNKS. */
  chunks: Blob[]
}

const RECORDER_TIMESLICE_MS = 500
const MAX_SPEECH_BUFFER_CHUNKS = 16

function awaitStop(recorder: MediaRecorderLike): Promise<void> {
  return new Promise((resolve) => {
    recorder.onstop = (): void => {
      resolve()
    }
  })
}

async function replayBufferedSpeech(
  buffered: SpeechBuffer,
  session: RealtimeSessionLike,
  ipc: VoiceChatIpc,
  capture: (err: unknown, ctx: { operation: string; step: string }) => void
): Promise<void> {
  if (buffered.recorder.state === 'recording') {
    const stopped = awaitStop(buffered.recorder)
    try {
      buffered.recorder.stop()
      await stopped
    } catch (err) {
      capture(err, { operation: 'voiceChatService', step: 'recorder_stop' })
    }
  }

  if (buffered.chunks.length === 0) return

  const blob = new Blob(buffered.chunks, {
    type: buffered.chunks[0]?.type ?? 'audio/webm'
  })
  try {
    const transcript = await ipc.transcribeAudio(blob)
    const trimmed = transcript.trim()
    if (trimmed.length === 0) return
    session.sendMessage(trimmed)
  } catch (err) {
    capture(err, {
      operation: 'voiceChatService',
      step: 'buffered_speech_replay'
    })
  }
}

export function makeActivationProgram(a: ActivationDeps): ActivationProgram {
  const { deps, emit, keyCacheGet } = a
  const capture = deps.captureError ?? (() => undefined)

  function buildSession(
    bookId: number,
    ctx: VoiceChatContext,
    mediaStream: MediaStreamLike,
    audioElement: AudioElementLike
  ): BuiltSession {
    const webrtcStream = deps.media.cloneStreamForWebrtcSend(mediaStream)
    const transport = deps.webrtcFactory({ mediaStream: webrtcStream, audioElement })

    let liveSession: RealtimeSessionLike | null = null

    const agent = deps.agentFactory({
      bookId,
      pageText: ctx.pageText,
      outline: ctx.outline,
      activeParagraphText: ctx.activeParagraphText,
      visualSummary: ctx.visualSummary,
      onEndConversation: (reason) => emit.endedByAgent(reason),
      onInspectImage: (image) => {
        liveSession?.addImage(image.dataUrl, { triggerResponse: false })
      },
      rag: deps.rag,
      language: deps.getLanguage()
    })
    const session = deps.sessionFactory(agent, {
      transport,
      apiKey: '',
      serverVad: deps.config.serverVad
    })
    liveSession = session

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
      emit.chatStatus('thinking')
    }
    const onToolEnd = (): void => {
      deps.effects.stopThinkingSound()
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
      try {
        webrtcStream.getTracks().forEach((t) => t.stop())
      } catch (err) {
        capture(err, { operation: 'voiceChatService', step: 'webrtc_clone_stop' })
      }
    }

    return { session, cleanup }
  }

  const activationPipeline = (
    bookId: number,
    ctx: VoiceChatContext
  ): Effect.Effect<SessionHandle, ActivationError> => {
    let success = false

    return Effect.scoped(
      Effect.gen(function* () {
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

        const vad = yield* Effect.acquireRelease(
          Effect.sync(() => deps.vad.create(mediaStream)),
          (v) =>
            Effect.sync(() => {
              if (!success && v) v.dispose()
            })
        )

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

        const buffered = yield* Effect.acquireRelease(
          Effect.sync((): SpeechBuffer | null => {
            if (!deps.config.bufferedSpeechReplayEnabled) return null
            if (!deps.media.createMediaRecorder) return null
            try {
              const recorder = deps.media.createMediaRecorder(mediaStream)
              if (!recorder) return null
              const chunks: Blob[] = []
              recorder.ondataavailable = (e) => {
                if (!e.data || e.data.size === 0) return
                chunks.push(e.data)
                while (chunks.length > MAX_SPEECH_BUFFER_CHUNKS) chunks.shift()
              }
              recorder.start(RECORDER_TIMESLICE_MS)
              return { recorder, chunks }
            } catch (err) {
              capture(err, {
                operation: 'voiceChatService',
                step: 'recorder_construct'
              })
              return null
            }
          }),
          (b) =>
            Effect.sync(() => {
              if (!success && b && b.recorder.state === 'recording') {
                try {
                  b.recorder.stop()
                } catch (err) {
                  capture(err, {
                    operation: 'voiceChatService',
                    step: 'recorder_stop_on_failure'
                  })
                }
              }
            })
        )

        const apiKey = yield* Effect.tryPromise({
          try: () => keyCacheGet(),
          catch: (e) => new AuthFailedError({ message: msgOf(e) })
        })

        yield* Effect.tryPromise({
          try: () => built.session.connect({ apiKey }),
          catch: (e) => new ConnectFailedError({ message: msgOf(e) })
        }).pipe(
          Effect.timeoutFail({
            duration: Duration.millis(deps.config.connectTimeoutMs),
            onTimeout: () => new ConnectTimeoutError({ ms: deps.config.connectTimeoutMs })
          })
        )

        if (vad) {
          const vadRef = vad
          yield* Effect.async<void, never>((resume) => {
            vadRef.waitForSpeechEnd(deps.config.connectTimeoutMs).then(
              () => resume(Effect.void),
              (err: unknown) => {
                if (err instanceof VadTimeoutError || err instanceof VadDisposedError) {
                  resume(Effect.void)
                } else {
                  resume(Effect.die(err))
                }
              }
            )
            return Effect.sync(() => vadRef.dispose())
          })
        }

        if (buffered) {
          yield* Effect.promise(() =>
            replayBufferedSpeech(buffered, built.session, deps.ipc, capture)
          )
        }

        yield* Effect.sync(() => {
          built.session.mute(false)
          audioElement.muted = false
        })

        success = true

        return {
          session: built.session,
          mediaStream,
          audioElement,
          cleanup: built.cleanup,
          vad
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
          const cause = exit.cause
          if (Cause.isInterruptedOnly(cause)) {
            reject(new Error('__VOICE_CHAT_INTERRUPTED__'))
            return
          }
          const failures = Array.from(Cause.failures(cause))
          const first = failures.length > 0 ? failures[0] : null
          if (first) {
            reject(toPublicError(first))
            return
          }
          reject(new Error(Cause.pretty(cause)))
        })
      })
      return { promise, fiber }
    }
  }
}

// Silence unused-export warning for SessionError — re-exported by errors.ts.
void SessionError
