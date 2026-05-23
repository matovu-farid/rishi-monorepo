import type { Fiber } from 'effect'
import { Effect, Duration, Cause, Exit } from 'effect'
import { captureError } from '@/utils/sentry'
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
  /** Null when AudioContext is unavailable. service.ts disposes alongside the session. */
  readonly vad: LocalVoiceVad | null
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

/** Captures speech the user uttered during the connect window. */
interface SpeechBuffer {
  recorder: MediaRecorderLike
  /** Rolling buffer of MediaRecorder timeslice chunks. Capped at MAX_SPEECH_BUFFER_CHUNKS. */
  chunks: Blob[]
}

/**
 * Recorder timeslice in ms. A small timeslice lets us trim the oldest chunks
 * to enforce a rolling window cap, instead of holding the whole connect
 * window in one giant blob.
 */
const RECORDER_TIMESLICE_MS = 500

/**
 * Maximum rolling buffer size. 16 × 500ms = 8 s of audio. Anything older is
 * dropped — on bad networks a connect can take >10s, and a Deepgram round
 * trip on a multi-second blob just to re-inject ancient speech is worse UX
 * than dropping it. The cap also bounds memory.
 */
const MAX_SPEECH_BUFFER_CHUNKS = 16

/**
 * Wait for the recorder's `onstop` callback, then resolve. Some browsers fire
 * a final `ondataavailable` between stop() being called and onstop firing, so
 * we must wait rather than reading `chunks` immediately after `stop()`.
 */
function awaitStop(recorder: MediaRecorderLike): Promise<void> {
  return new Promise((resolve) => {
    recorder.onstop = (): void => {
      resolve()
    }
  })
}

/**
 * Transcribe whatever the user said during the connect window and inject it
 * as a text message into the live session. Best-effort: every failure mode
 * is logged via Sentry but never rethrown — the caller has already promised
 * a live session, we just enrich it.
 *
 * Awaited (not fire-and-forget): the caller gates `mute(false)` on this
 * completing, so the live mic only goes hot after the agent has seen the
 * buffered text. Without that, the same words can land at OpenAI twice
 * (once as buffered text, once as live WebRTC audio).
 */
async function replayBufferedSpeech(
  buffered: SpeechBuffer,
  session: RealtimeSessionLike,
  ipc: VoiceChatIpc
): Promise<void> {
  // Only wait for onstop if we actually need to stop. If the recorder is
  // already inactive (test fixtures, or some other path stopped it), we'd
  // deadlock forever waiting for an onstop that will never fire. And if
  // stop() itself throws, onstop also won't fire — handle that too.
  if (buffered.recorder.state === 'recording') {
    const stopped = awaitStop(buffered.recorder)
    try {
      buffered.recorder.stop()
      await stopped
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'recorder_stop' })
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
    captureError(err, {
      operation: 'voiceChatService',
      step: 'buffered_speech_replay'
    })
  }
}

export function makeActivationProgram(a: ActivationDeps): ActivationProgram {
  const { deps, emit, keyCacheGet } = a

  function buildSession(
    bookId: number,
    ctx: VoiceChatContext,
    mediaStream: MediaStreamLike,
    audioElement: AudioElementLike
  ): BuiltSession {
    // Clone the mic stream's audio tracks into a dedicated WebRTC-send stream
    // whose tracks start disabled. The SDK's OpenAIRealtimeWebRTC.connect()
    // does `peerConnection.addTrack(stream.getAudioTracks()[0])`, and that
    // track's `enabled` flag controls whether RTP carries voice or silence.
    // The VAD gate + buffered-speech replay below run while the clone is
    // hard-muted; `session.mute(false)` flips the cloned sender track live via
    // `peerConnection.getSenders()` once the gate completes. The source
    // mediaStream is left untouched so MediaRecorder and local VAD keep seeing
    // real audio for the buffered-replay window.
    const webrtcStream = deps.media.cloneStreamForWebrtcSend(mediaStream)
    const transport = deps.webrtcFactory({ mediaStream: webrtcStream, audioElement })

    // Forward captured images into the live session. The session is created
    // below, so we close over a mutable holder that's filled in immediately
    // after agentFactory returns.
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
      // Stop the cloned WebRTC-send tracks. The SDK's `close()` does
      // `peerConnection.close()` but leaves added tracks `live`, which keeps
      // the OS mic indicator on and pins the underlying device.
      try {
        webrtcStream.getTracks().forEach((t) => t.stop())
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'webrtc_clone_stop' })
      }
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
        // Mic with echoCancellation + noiseSuppression so TTS playback doesn't
        // bleed back into the realtime stream as billable audio input.
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

        // Local VAD attaches to the same MediaStream as the recorder and the
        // session transport. Sharing the stream across MediaRecorder +
        // AudioContext.createMediaStreamSource is a supported Chromium pattern.
        // VadPort.create() may return null if AudioContext is unavailable; the
        // pipeline degrades to current behavior (no gating) in that case.
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

        // Speech-buffer recorder. Starts before connect so words spoken during
        // the connect window land in the rolling buffer; once connect resolves
        // we drain and inject them as a text message. Gated behind a config
        // flag so the feature can be flipped off in production without a code
        // change, and degrades silently when the platform lacks MediaRecorder.
        const buffered = yield* Effect.acquireRelease(
          Effect.sync((): SpeechBuffer | null => {
            if (!deps.config.bufferedSpeechReplayEnabled) return null
            if (!deps.media.createMediaRecorder) return null
            try {
              const recorder = deps.media.createMediaRecorder(mediaStream)
              if (!recorder) return null
              const chunks: Blob[] = []
              recorder.ondataavailable = (e) => {
                if (e.data.size === 0) return
                chunks.push(e.data)
                // Rolling cap: drop oldest chunks so long connect windows
                // don't accumulate megabytes of audio.
                while (chunks.length > MAX_SPEECH_BUFFER_CHUNKS) chunks.shift()
              }
              recorder.start(RECORDER_TIMESLICE_MS)
              return { recorder, chunks }
            } catch (err) {
              captureError(err, {
                operation: 'voiceChatService',
                step: 'recorder_construct'
              })
              return null
            }
          }),
          (b) =>
            Effect.sync(() => {
              // On activation failure: stop the recorder so its hooks detach
              // and the buffer is dropped. On success: replayBufferedSpeech
              // owns the stop.
              if (!success && b?.recorder.state === 'recording') {
                try {
                  b.recorder.stop()
                } catch (err) {
                  captureError(err, {
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

        // VAD gate: hold here until the user has finished their utterance (or
        // never spoke). Without this, the buffered recorder gets stopped mid-
        // sentence and Deepgram returns a partial transcript — the agent
        // responds to half a thought, then the live mic opens and the user's
        // tail-of-sentence creates a duplicate turn that interrupts the agent.
        //
        // Implemented with Effect.async (not Effect.promise) so a fiber
        // interrupt during a pending wait runs the cleanup → vad.dispose() →
        // pending promise rejects with VadDisposedError → Effect.async resumes.
        // Plain Effect.promise would be uninterruptible and could stall the
        // fiber up to connectTimeoutMs after the user taps deactivate().
        // VadTimeoutError / VadDisposedError are swallowed — both mean
        // "proceed with whatever the buffer holds." The connect timeout
        // budget is reused as the VAD safety ceiling.
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

        // Replay buffered speech BEFORE unmuting the live mic. If we unmute
        // first and the user is still talking, the same words land at OpenAI
        // twice — once as the buffered transcript, once as live WebRTC audio.
        // Awaited (not fire-and-forget) for this exact reason; the replay
        // helper bounds its own latency via the buffer cap.
        if (buffered) {
          yield* Effect.promise(() => replayBufferedSpeech(buffered, built.session, deps.ipc))
        }

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
