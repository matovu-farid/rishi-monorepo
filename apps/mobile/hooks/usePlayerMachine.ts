/**
 * Mobile usePlayerMachine — wires the shared `playerMachine` XState actor to
 * expo-audio and the new TTS service (Batch 3) for **every** mobile reader
 * format. Ported in spirit from
 * `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`.
 *
 * What it owns:
 *
 *   1. The XState actor lifecycle (create on mount, stop on unmount).
 *   2. machine -> store sync (`playingState`, `activeParagraph`, `errors`).
 *   3. store -> machine sync (`currentParagraphs`, `nextPageParagraphs`,
 *      `prevPageParagraphs`).
 *   4. Audio side-effects: when the machine enters `loading`, request audio
 *      from `getTtsService()` and play it via expo-audio. When the audio
 *      ends, send `AUDIO_ENDED`. On error, `AUDIO_ERROR`.
 *   5. Expose a `send` callback so screen-level UI can dispatch PLAY /
 *      PAUSE / STOP / NEXT / PREV / PLAY_FROM events.
 *
 * Differences from electron:
 *
 *   - expo-audio instead of HTMLAudioElement: the player exposes
 *     `addListener('playbackStatusUpdate', ...)` which fires `didJustFinish`
 *     when the clip ends (analogous to `audio.ended`).
 *   - No nav-store integration. epubjs-react-native fires onLocationChange
 *     when the user paginates; the reader is responsible for updating
 *     `currentParagraphs` itself.
 *   - Prefetch is left to the screen-level reader (which knows
 *     `nextPageParagraphs`) — the hook handles only the current paragraph
 *     fetch in the `loading` state.
 *
 * Mocking in tests: the hook is fully driven by injectable defaults. Tests
 * pass an override via `buildTtsService({ fetch: jest.fn(), ... })` BEFORE
 * the hook mounts and inject a custom audio player via the hook's
 * `audioPlayer` prop. Without overrides, the hook uses the production
 * service + a real expo-audio player.
 */
import { useEffect, useRef } from 'react'
import { createActor } from 'xstate'
import { playerMachine } from '@rishi/shared/machines/playerMachine'
import type {
  ParagraphWithIndex,
  PlayerMachineEvent,
} from '@rishi/shared/machines/playerMachine'
import { createAudioPlayer } from 'expo-audio'
import { usePlayerStore, type PlayerStoreState, type PlayerSend } from '@/lib/stores/playerStore'
import { getTtsService } from '@/lib/tts/tts-service'

// Map XState machine state value to PlayerStoreState string. Compound
// states like `{ paused: 'clean' }` are projected to `paused.clean`.
function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  const entry = Object.entries(value)[0]
  if (!entry) return 'idle'
  const [parent, child] = entry
  return `${parent}.${child}` as PlayerStoreState
}

/**
 * Audio adapter interface — abstracts the parts of expo-audio the hook
 * needs. Tests inject a fake; production wraps `createAudioPlayer()`.
 */
export interface PlayerAudioAdapter {
  replace(source: { uri: string }): void
  play(): void
  pause(): void
  remove(): void
  /** Returns the unsubscribe callback. */
  addEndedListener(cb: () => void): () => void
  /** Returns the unsubscribe callback. */
  addErrorListener(cb: (msg: string) => void): () => void
}

/**
 * Build a default audio adapter on top of expo-audio's `createAudioPlayer`.
 * Returns the adapter + a teardown function.
 */
export function buildDefaultAudioAdapter(): {
  adapter: PlayerAudioAdapter
  destroy: () => void
} {
  const player = createAudioPlayer()
  const endedCbs = new Set<() => void>()
  const errorCbs = new Set<(msg: string) => void>()

  const sub = player.addListener('playbackStatusUpdate', (event: { didJustFinish?: boolean; error?: string | null }) => {
    if (event.didJustFinish) {
      for (const cb of endedCbs) cb()
    } else if (event.error) {
      for (const cb of errorCbs) cb(event.error)
    }
  })

  const adapter: PlayerAudioAdapter = {
    replace: (source) => {
      player.replace(source)
    },
    play: () => {
      player.play()
    },
    pause: () => {
      player.pause()
    },
    remove: () => {
      player.remove()
    },
    addEndedListener: (cb) => {
      endedCbs.add(cb)
      return () => endedCbs.delete(cb)
    },
    addErrorListener: (cb) => {
      errorCbs.add(cb)
      return () => errorCbs.delete(cb)
    },
  }

  return {
    adapter,
    destroy: () => {
      try {
        sub.remove()
      } catch {
        /* ignore */
      }
      try {
        player.remove()
      } catch {
        /* ignore */
      }
    },
  }
}

export interface UsePlayerMachineOptions {
  /** Override the audio adapter (tests). */
  audio?: PlayerAudioAdapter
}

export interface UsePlayerMachineResult {
  send: PlayerSend
}

/**
 * React hook. Mount once per reader screen. Subsequent re-renders are
 * inexpensive; the actor is rebuilt only when `bookId` changes.
 */
export function usePlayerMachine(
  bookId: string,
  options: UsePlayerMachineOptions = {},
): UsePlayerMachineResult {
  const sendRef = useRef<PlayerSend>(() => {})

  useEffect(() => {
    if (!bookId) return

    const actor = createActor(playerMachine)
    let teardownAudio: (() => void) | null = null
    let audio: PlayerAudioAdapter
    if (options.audio) {
      audio = options.audio
    } else {
      const built = buildDefaultAudioAdapter()
      audio = built.adapter
      teardownAudio = built.destroy
    }

    let prevState: PlayerStoreState | '' = ''
    // Generation counter to ignore stale fetches that resolve after the
    // machine has moved past their loading entry.
    let fetchGeneration = 0
    let didStop = false

    // --- 1. machine -> store sync ---
    const machineUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const currentParagraph: ParagraphWithIndex | null =
        ctx.currentParagraphs[ctx.paragraphIndex] ?? null

      let nextActive: ParagraphWithIndex | null
      if (state === 'playing') {
        nextActive = currentParagraph
      } else if (state === 'paused.clean') {
        nextActive = usePlayerStore.getState().activeParagraph
      } else {
        nextActive = null
      }

      usePlayerStore.setState({
        playingState: state,
        activeParagraph: nextActive,
        errors: ctx.errors,
      })
    })

    // --- 2. store -> machine sync (paragraphs) ---
    const unsubCurrent = usePlayerStore.subscribe(
      (s) => s.currentParagraphs,
      (paragraphs) => {
        actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
      },
    )
    const unsubNext = usePlayerStore.subscribe(
      (s) => s.nextPageParagraphs,
      (paragraphs) => {
        actor.send({ type: 'NEXT_PARAGRAPHS_UPDATED', paragraphs })
      },
    )
    const unsubPrev = usePlayerStore.subscribe(
      (s) => s.prevPageParagraphs,
      (paragraphs) => {
        actor.send({ type: 'PREV_PARAGRAPHS_UPDATED', paragraphs })
      },
    )

    // --- 3. machine -> audio side-effects ---
    const audioUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const paragraph = ctx.currentParagraphs[ctx.paragraphIndex] as
        | ParagraphWithIndex
        | undefined

      if (state === 'loading') {
        // Silence the previous audio
        try {
          audio.pause()
        } catch {
          /* ignore */
        }
        const gen = ++fetchGeneration

        if (!paragraph || ctx.currentParagraphs.length === 0) {
          // Image-only page: skip after a beat.
          setTimeout(() => {
            if (gen !== fetchGeneration || didStop) return
            actor.send({ type: 'AUDIO_ENDED' })
          }, 1000)
        } else {
          const useOverride =
            ctx.partialFirstText !== null &&
            ctx.partialFirstParagraphIndex === ctx.paragraphIndex
          const ttsText = useOverride ? ctx.partialFirstText! : paragraph.text
          const ttsKey = useOverride ? ctx.partialFirstKey! : paragraph.index

          if (!ttsText.trim()) {
            setTimeout(() => {
              if (gen !== fetchGeneration || didStop) return
              actor.send({ type: 'NEXT' })
            }, 500)
          } else {
            getTtsService()
              .requestAudio({
                bookId: ctx.bookId,
                cfiRange: ttsKey,
                text: ttsText,
                priority: 1,
              })
              .then((uri) => {
                if (gen !== fetchGeneration || didStop) return
                audio.replace({ uri })
                audio.play()
                actor.send({ type: 'AUDIO_LOADED' })
              })
              .catch((err: unknown) => {
                if (gen !== fetchGeneration || didStop) return
                const msg = err instanceof Error ? err.message : String(err)
                console.error(`[player] audio fetch/load failed: ${msg}`)
                actor.send({ type: 'AUDIO_ERROR', error: msg })
              })
          }
        }
      } else {
        // Left loading — invalidate any in-flight fetch
        fetchGeneration++
      }

      if (state === 'playing' && prevState === 'paused.clean') {
        try {
          audio.play()
        } catch {
          /* ignore */
        }
      }
      if (state.startsWith('paused') && prevState === 'playing') {
        try {
          audio.pause()
        } catch {
          /* ignore */
        }
      }
      if (state === 'stopped' && prevState !== 'stopped' && prevState !== 'idle') {
        try {
          audio.pause()
        } catch {
          /* ignore */
        }
      }
      if (state === 'idle' && prevState !== 'idle') {
        try {
          audio.pause()
        } catch {
          /* ignore */
        }
        try {
          getTtsService().cancelBookRequests(bookId)
        } catch {
          /* ignore */
        }
      }
      prevState = state
    })

    // --- 4. audio -> machine callbacks ---
    const unsubEnded = audio.addEndedListener(() => {
      actor.send({ type: 'AUDIO_ENDED' })
    })
    const unsubError = audio.addErrorListener((msg) => {
      actor.send({ type: 'AUDIO_ERROR', error: msg })
    })

    // --- 5. expose send ---
    const send: PlayerSend = (event: PlayerMachineEvent) => actor.send(event)
    sendRef.current = send
    usePlayerStore.getState().setSend(send)

    actor.start()
    actor.send({ type: 'INITIALIZE', bookId })

    // Seed paragraphs from store if a previous mount populated them.
    const seeded = usePlayerStore.getState().currentParagraphs
    if (seeded.length > 0) {
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: seeded })
    }

    return () => {
      didStop = true
      try {
        actor.send({ type: 'CLEANUP' })
      } catch {
        /* ignore */
      }
      machineUnsub.unsubscribe()
      audioUnsub.unsubscribe()
      unsubCurrent()
      unsubNext()
      unsubPrev()
      unsubEnded()
      unsubError()
      usePlayerStore.getState().setSend(() => {})
      try {
        getTtsService().cancelBookRequests(bookId)
      } catch {
        /* ignore */
      }
      try {
        actor.stop()
      } catch {
        /* ignore */
      }
      if (teardownAudio) teardownAudio()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookId])

  return {
    send: sendRef.current,
  }
}
