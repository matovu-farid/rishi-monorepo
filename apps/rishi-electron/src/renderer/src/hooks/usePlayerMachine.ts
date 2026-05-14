// apps/electron/src/renderer/src/hooks/usePlayerMachine.ts
import { useEffect, useRef } from 'react'
import { createActor } from 'xstate'
import { playerMachine } from '@/machines/playerMachine'
import { usePlayerStore } from '@/stores/playerStore'
import type { PlayerStoreState, PlayerSend } from '@/stores/playerStore'
import { getTtsService } from '@/services'
import { usePdfStore } from '@/stores/pdfStore'
import isEqual from 'fast-deep-equal'
import type { TextItem, TextMarkedContent } from 'react-pdf'

// Singleton HTMLAudioElement for TTS playback
const audioElement = new Audio()

// Map XState machine state value to PlayerStoreState string
function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  // Compound state: { paused: "clean" } -> "paused.clean"
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

export function usePlayerMachine(bookId: string) {
  const actorRef = useRef<ReturnType<typeof createActor<typeof playerMachine>> | null>(null)
  const sendRef = useRef<PlayerSend>(() => {})

  useEffect(() => {
    // Create and start the machine actor
    const actor = createActor(playerMachine)
    actorRef.current = actor

    // --- 1. Machine -> store sync ---
    const machineUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const currentParagraph = ctx.currentParagraphs[ctx.paragraphIndex] ?? null

      usePlayerStore.setState({
        playingState: state,
        activeParagraph:
          state === 'playing' ? currentParagraph : usePlayerStore.getState().activeParagraph,
        errors: ctx.errors
      })
    })

    // --- 2. Store -> machine sync (paragraphs) ---
    // Use deep equality so reference-different but content-identical arrays
    // don't trigger spurious PARAGRAPHS_UPDATED events (which would interrupt
    // playback by transitioning playing -> loading).
    const unsubCurrent = usePlayerStore.subscribe(
      (s) => s.currentParagraphs,
      (paragraphs) => {
        actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
        // Only prefetch when player is actively playing/loading
        const machineState = mapStateValue(actor.getSnapshot().value)
        if (machineState === 'playing' || machineState === 'loading') {
          for (const p of paragraphs) {
            if (p.text.trim()) {
              void getTtsService()
                .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
                .catch((err: unknown) => console.warn('[player] audio prefetch failed:', err))
            }
          }
        }
      },
      { equalityFn: isEqual }
    )
    const unsubNext = usePlayerStore.subscribe(
      (s) => s.nextPageParagraphs,
      (paragraphs) => {
        actor.send({ type: 'NEXT_PARAGRAPHS_UPDATED', paragraphs })
        // Only prefetch when player is actively playing/loading
        const machineState = mapStateValue(actor.getSnapshot().value)
        if (machineState === 'playing' || machineState === 'loading') {
          for (const p of paragraphs) {
            if (p.text.trim()) {
              void getTtsService()
                .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
                .catch((err: unknown) => console.warn('[player] next page prefetch failed:', err))
            }
          }
        }
      },
      { equalityFn: isEqual }
    )
    const unsubPrev = usePlayerStore.subscribe(
      (s) => s.prevPageParagraphs,
      (paragraphs) => {
        actor.send({ type: 'PREV_PARAGRAPHS_UPDATED', paragraphs })
      },
      { equalityFn: isEqual }
    )

    // --- 3. Machine actions -> audio side effects ---
    let prevState = ''
    // Generation counter to cancel stale fetches when a new loading entry fires
    let fetchGeneration = 0
    const audioUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const paragraph = ctx.currentParagraphs[ctx.paragraphIndex]

      if (state === 'loading') {
        // Clear old highlight immediately
        usePlayerStore.setState({ activeParagraph: null })
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
        } else if (!paragraph.text.trim()) {
          // Empty paragraph (e.g. image content). Skip after brief pause.
          setTimeout(() => {
            if (gen !== fetchGeneration) return
            actor.send({ type: 'NEXT' })
          }, 2000)
        } else {
          // Fetch audio via TTS service (returns blob URL in Electron)
          getTtsService()
            .requestAudio({
              bookId: ctx.bookId,
              cfiRange: paragraph.index,
              text: paragraph.text,
              priority: 1
            })
            .then((blobUrl) => {
              if (gen !== fetchGeneration) return // stale
              return loadAndPlayAudio(blobUrl)
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

      if (state === 'stopped' && prevState !== 'stopped' && prevState !== 'idle') {
        stopAudio()
        usePlayerStore.setState({
          activeParagraph: null,
          endedParagraph: null
        })
      }

      if (state === 'waitingForParagraphs') {
        stopAudio()
        const direction = actor.getSnapshot().context.direction
        usePlayerStore.setState({
          pageRequest: direction === 'backward' ? 'prev' : 'next'
        })
      }

      if (state === 'idle' && prevState !== 'idle') {
        cleanupAudio(bookId)
        usePlayerStore.setState({
          activeParagraph: null,
          endedParagraph: null,
          lastMove: null,
          errors: [],
          pageRequest: null
        })
      }

      prevState = state
    })

    // --- 4. Track NEXT/PREV moves for highlight removal ---
    const originalSend = actor.send.bind(actor)
    const wrappedSend: PlayerSend = (event) => {
      if (event.type === 'NEXT' || event.type === 'PREV') {
        const ctx = actor.getSnapshot().context
        const fromParagraph = ctx.currentParagraphs[ctx.paragraphIndex] ?? null
        originalSend(event)
        const newCtx = actor.getSnapshot().context
        const toParagraph = newCtx.currentParagraphs[newCtx.paragraphIndex] ?? null
        if (fromParagraph && toParagraph) {
          usePlayerStore.setState({
            lastMove: {
              from: fromParagraph,
              to: toParagraph,
              direction: event.type === 'NEXT' ? 'forward' : 'backward'
            }
          })
        }
        return
      }
      originalSend(event)
    }
    sendRef.current = wrappedSend
    usePlayerStore.getState().setSend(wrappedSend)

    // --- 5. AudioElement -> machine callbacks ---
    const handleEnded = () => {
      const ctx = actor.getSnapshot().context
      const endedParagraph = ctx.currentParagraphs[ctx.paragraphIndex] ?? null
      usePlayerStore.setState({ endedParagraph })
      actor.send({ type: 'AUDIO_ENDED' })
    }
    const handleError = () => {
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

    // --- Start actor and initialize ---
    actor.start()
    actor.send({ type: 'INITIALIZE', bookId })

    // Seed paragraphs from PDF store if available
    const pdfState = usePdfStore.getState()
    const pdfPageData = pdfState.pageNumberToPageData[pdfState.pageNumber]
    if (pdfPageData) {
      // Convert text content items to paragraphs
      const items = pdfPageData.items || []
      const paragraphs = items
        .filter(
          (item: TextItem | TextMarkedContent): item is TextItem =>
            'str' in item && item.str.trim() !== ''
        )
        .map((item: TextItem, idx: number) => ({
          index: `pdf-${pdfState.pageNumber}-${idx}`,
          text: item.str
        }))
      if (paragraphs.length > 0) {
        usePlayerStore.getState().setCurrentParagraphs(paragraphs)
      }
    }

    // Also forward any paragraphs already in the store
    const currentParagraphs = usePlayerStore.getState().currentParagraphs
    if (currentParagraphs.length > 0) {
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: currentParagraphs })
    }

    return () => {
      actor.send({ type: 'CLEANUP' })
      machineUnsub.unsubscribe()
      audioUnsub.unsubscribe()
      unsubCurrent()
      unsubNext()
      unsubPrev()
      audioElement.removeEventListener('ended', handleEnded)
      audioElement.removeEventListener('error', handleError)
      usePlayerStore.getState().setSend(() => {})
      cleanupAudio(bookId)
      actor.stop()
      actorRef.current = null
    }
  }, [bookId])

  return {
    // Why: sendRef.current holds the stable wrapped send function created in useEffect; callers consume the returned object synchronously. The ref's identity is stable across renders; only its current value swaps when the actor is recreated.
    // eslint-disable-next-line react-hooks/refs
    send: sendRef.current
  }
}

// --- Audio helpers (inline, uses the singleton audioElement) ---

async function loadAndPlayAudio(blobUrl: string): Promise<void> {
  audioElement.pause()
  audioElement.currentTime = 0
  audioElement.src = blobUrl
  audioElement.load()

  await new Promise<void>((resolve, reject) => {
    const handleCanPlay = () => {
      audioElement.removeEventListener('canplaythrough', handleCanPlay)
      audioElement.removeEventListener('error', handleError)
      resolve()
    }
    const handleError = (e: Event) => {
      audioElement.removeEventListener('canplaythrough', handleCanPlay)
      audioElement.removeEventListener('error', handleError)
      const mediaError = (e.target as HTMLAudioElement)?.error
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

  await audioElement.play()
}

function stopAudio(): void {
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
