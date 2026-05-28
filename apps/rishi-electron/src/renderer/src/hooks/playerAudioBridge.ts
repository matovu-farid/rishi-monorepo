// apps/electron/src/renderer/src/hooks/playerAudioBridge.ts
//
// Self-contained audio side-effect adapter for the player state machine.
//
// What it owns:
//   - The singleton HTMLAudioElement used for TTS playback.
//   - The TTS fetch lifecycle on entering `loading`: stale-fetch invalidation
//     via a generation counter, AUDIO_LOADED / AUDIO_ERROR replies to the
//     actor, partial-first override application.
//   - Pause/resume/stop in response to machine state transitions.
//   - Forwarding HTMLAudioElement 'ended' / 'error' events back into the
//     actor as AUDIO_ENDED / AUDIO_ERROR.
//   - Prefetch scheduling for upcoming paragraphs on the current + next page.
//
// What it explicitly does NOT own (lives in playerOrchestrationBridge):
//   - `usePlayerStore.activeParagraph` clearing on state transitions.
//   - `pageRequest` writes on `waitingForParagraphs`.
//   - `publishCurrentEpubParagraphs()` on `republishingParagraphs`.
//
// Splitting the two halves out of the previous god-hook means the audio
// concern is independently testable and re-implementable when Phase 3
// migrates it to an `audioActor` (xstate `fromCallback`).
import type { createActor } from 'xstate'
import type { playerMachine } from '@/machines/playerMachine'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex } from '@/stores/playerStore'
import { getTtsService } from '@/services'
import type { PlayerStoreState } from '@/stores/playerStore'

type PlayerActor = ReturnType<typeof createActor<typeof playerMachine>>

// Singleton HTMLAudioElement for TTS playback. Exported so E2E tests can
// observe `paused` / `src` to verify the player stops the previous page's
// audio when navigating mid-playback.
export const audioElement = new Audio()

function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

/**
 * Wire the playerMachine actor's state stream to the singleton audio
 * element. Returns a teardown that unsubscribes everything and stops audio.
 */
export function wireAudioBridge(actor: PlayerActor, bookId: string): () => void {
  let prevState = ''
  let fetchGeneration = 0

  const audioUnsub = actor.subscribe((snapshot) => {
    const state = mapStateValue(snapshot.value)
    const ctx = snapshot.context
    const paragraph = ctx.currentParagraphs[ctx.paragraphIndex] as
      | ParagraphWithIndex
      | undefined

    if (state === 'loading') {
      // Silence the previous page's audio immediately so it doesn't bleed
      // into the new page while the next TTS fetch is in flight.
      stopAudio()
      // Increment generation so any in-flight fetch from a previous attempt
      // is ignored when it resolves.
      const gen = ++fetchGeneration
      if (!paragraph || ctx.currentParagraphs.length === 0) {
        // No paragraphs on this page (image-only page).
        // Pause briefly then auto-advance to next page.
        setTimeout(() => {
          if (gen !== fetchGeneration) return
          actor.send({ type: 'AUDIO_ENDED' })
        }, 2000)
      } else {
        // When a partial-first override is active for this paragraph, use the
        // override text/key instead of the full paragraph content so TTS
        // starts from the user's selection point.
        const useOverride =
          ctx.partialFirstText !== null && ctx.partialFirstParagraphIndex === ctx.paragraphIndex
        const ttsText = useOverride ? ctx.partialFirstText! : paragraph.text
        const ttsKey = useOverride ? ctx.partialFirstKey! : paragraph.index

        if (!ttsText.trim()) {
          // Empty paragraph (or selection resolved to whitespace). Skip.
          setTimeout(() => {
            if (gen !== fetchGeneration) return
            actor.send({ type: 'NEXT' })
          }, 2000)
        } else {
          // Fetch audio via TTS service (returns blob URL in Electron)
          getTtsService()
            .requestAudio({
              bookId: ctx.bookId,
              cfiRange: ttsKey,
              text: ttsText,
              priority: 1
            })
            .then((blobUrl) => {
              if (gen !== fetchGeneration) return // stale
              return loadAndPlayAudio(blobUrl, () => gen !== fetchGeneration)
            })
            .then(() => {
              if (gen !== fetchGeneration) return // stale
              actor.send({ type: 'AUDIO_LOADED' })
              // Update activeParagraph now that audio is playing
              usePlayerStore.setState({ activeParagraph: paragraph })
              // Schedule prefetch for upcoming paragraphs
              schedulePrefetch(
                ctx.paragraphIndex,
                ctx.currentParagraphs,
                ctx.nextPageParagraphs,
                ctx.bookId
              )
            })
            .catch((err: unknown) => {
              if (gen !== fetchGeneration) return // stale
              const msg = err instanceof Error ? err.message : String(err)
              console.error(`Audio fetch/load failed [p${ctx.paragraphIndex}]: ${msg}`)
              actor.send({ type: 'AUDIO_ERROR', error: msg })
            })
        }
      }
    } else {
      // Left loading state -- invalidate any in-flight fetch
      fetchGeneration++
    }

    if (state === 'playing' && prevState.startsWith('paused.clean')) {
      // Resume from clean pause
      void audioElement.play()
    }

    if (state.startsWith('paused') && prevState === 'playing') {
      audioElement.pause()
    }

    if (
      (state === 'stopped' && prevState !== 'stopped' && prevState !== 'idle') ||
      state === 'waitingForParagraphs' ||
      state === 'republishingParagraphs' ||
      state === 'pageNavigating'
    ) {
      // Any time the machine leaves an audible state without continuing
      // playback, stop the audio. Idempotent — multiple consecutive calls
      // are no-ops on an already-paused element.
      stopAudio()
    }

    if (state === 'idle' && prevState !== 'idle') {
      cleanupAudio(bookId)
    }

    prevState = state
  })

  // --- audioElement -> machine callbacks ---
  const handleEnded = (): void => {
    actor.send({ type: 'AUDIO_ENDED' })
  }
  const handleError = (): void => {
    const error = audioElement.error
    const code = error?.code
    const codeNames: Record<number, string> = {
      1: 'MEDIA_ERR_ABORTED',
      2: 'MEDIA_ERR_NETWORK',
      3: 'MEDIA_ERR_DECODE',
      4: 'MEDIA_ERR_SRC_NOT_SUPPORTED'
    }
    // Pick the first usable string out of (message, code label, default).
    // Empty error.message strings are treated as "missing" so we still fall
    // back to the friendlier code label.
    const msg =
      (error?.message && error.message.length > 0 ? error.message : null) ??
      (code !== undefined ? codeNames[code] : null) ??
      'Audio playback error'
    actor.send({ type: 'AUDIO_ERROR', error: msg })
  }

  audioElement.addEventListener('ended', handleEnded)
  audioElement.addEventListener('error', handleError)

  return () => {
    audioUnsub.unsubscribe()
    audioElement.removeEventListener('ended', handleEnded)
    audioElement.removeEventListener('error', handleError)
    cleanupAudio(bookId)
  }
}

// --- Audio helpers (operate on the singleton audioElement) ---

async function loadAndPlayAudio(blobUrl: string, isCancelled?: () => boolean): Promise<void> {
  audioElement.pause()
  audioElement.currentTime = 0
  audioElement.src = blobUrl
  audioElement.load()

  await new Promise<void>((resolve, reject) => {
    const handleCanPlay = (): void => {
      audioElement.removeEventListener('canplaythrough', handleCanPlay)
      audioElement.removeEventListener('error', handleError)
      resolve()
    }
    const handleError = (e: Event): void => {
      audioElement.removeEventListener('canplaythrough', handleCanPlay)
      audioElement.removeEventListener('error', handleError)
      const mediaError = (e.target as HTMLAudioElement | null)?.error
      // Empty message strings should fall back to the descriptive default so
      // we never reject with a blank `Error` message.
      const message =
        mediaError?.message && mediaError.message.length > 0
          ? mediaError.message
          : `Audio load error (code ${mediaError?.code ?? 'unknown'})`
      reject(new Error(message))
    }
    audioElement.addEventListener('canplaythrough', handleCanPlay, { once: true })
    audioElement.addEventListener('error', handleError, { once: true })
  })

  // After awaiting canplaythrough the state may have moved on (page flip,
  // STOP, etc). If so, do NOT call play() — it would play this now-stale
  // blob over whatever the player is currently loading.
  if (isCancelled?.()) return
  await audioElement.play()
}

/**
 * Stop playback without releasing the source. Idempotent.
 * Exported so the nav bridge can silence audio when an EPUB page-curl starts,
 * before the playerMachine has had a chance to enter `pageNavigating`.
 */
export function stopAudio(): void {
  audioElement.pause()
  audioElement.currentTime = 0
}

function cleanupAudio(bookId: string): void {
  audioElement.pause()
  audioElement.src = ''
  // Cancel any in-flight or pending TTS requests for this book.
  // Other books (e.g. library prefetch) keep running.
  getTtsService().cancelBookRequests(bookId)
}

let _prefetchTimer: ReturnType<typeof setTimeout> | null = null

function schedulePrefetch(
  currentIndex: number,
  currentParagraphs: { index: string; text: string }[],
  nextPageParagraphs: { index: string; text: string }[],
  bookId: string
): void {
  if (_prefetchTimer) clearTimeout(_prefetchTimer)
  _prefetchTimer = setTimeout(() => {
    // Prefetch next few paragraphs on current page
    for (let i = 1; i <= 5; i++) {
      const idx = currentIndex + i
      if (idx < currentParagraphs.length && currentParagraphs[idx].text.trim()) {
        void getTtsService()
          .requestAudio({
            bookId,
            cfiRange: currentParagraphs[idx].index,
            text: currentParagraphs[idx].text,
            priority: 0
          })
          .catch((err: unknown) => console.warn('[audio] prefetch current page failed:', err))
      }
    }
    // Prefetch next page paragraphs
    for (const p of nextPageParagraphs) {
      if (p.text.trim()) {
        void getTtsService()
          .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
          .catch((err: unknown) => console.warn('[audio] prefetch next page failed:', err))
      }
    }
  }, 200)
}
