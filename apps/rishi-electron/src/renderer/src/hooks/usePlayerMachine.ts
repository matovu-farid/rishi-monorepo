// apps/electron/src/renderer/src/hooks/usePlayerMachine.ts
import { useEffect, useRef } from 'react'
import { createActor } from 'xstate'
import { playerMachine } from '@/machines/playerMachine'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex, PlayerStoreState, PlayerSend } from '@/stores/playerStore'
import { useNavStore } from '@/stores/navStore'
import { getTtsService } from '@/services'
import { getVisualCueEmitter, resolveParagraphElement } from '@/services/tts'
import { usePdfStore } from '@/stores/pdfStore'
import { publishCurrentEpubParagraphs } from '@/stores/epubStore'
import isEqual from 'fast-deep-equal'
import type { TextItem, TextMarkedContent } from 'react-pdf'

// Singleton HTMLAudioElement for TTS playback. Exported so E2E tests can
// observe `paused`/`src` to verify the player stops the previous page's
// audio when navigating mid-playback.
export const audioElement = new Audio()

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
      const currentParagraph: ParagraphWithIndex | null =
        ctx.currentParagraphs[ctx.paragraphIndex] ?? null

      // Invariant: activeParagraph is what the user is *currently hearing*,
      // and it must be a paragraph on the visible page. It tracks the
      // visible page exactly: `playing` → live paragraph; `paused.clean` →
      // the paused-mid paragraph (paragraphs haven't changed); anything
      // else (loading, paused.stale, stopped, idle, waiting,
      // pageNavigating, error) → null. Previously this preserved the stale
      // value during loading, leaving the highlight on the OLD page until
      // the next TTS fetch resolved.
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
        errors: ctx.errors
      })

      if (nextActive) {
        const currentParagraphs = usePlayerStore.getState().currentParagraphs
        const idx = currentParagraphs.findIndex((p) => p.index === nextActive!.index)
        if (idx >= 0) {
          const element = resolveParagraphElement(idx)
          if (element) {
            getVisualCueEmitter().notifyParagraph({
              paragraphId: nextActive.index,
              element
            })
          }
        }
      }
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
        const ctx = actor.getSnapshot().context
        const machineState = mapStateValue(actor.getSnapshot().value)
        if (machineState === 'playing' || machineState === 'loading') {
          // When the override is active, skip prefetching the override paragraph
          // because it has a different cache key (partialFirstKey) than the full
          // paragraph — prefetching with the full key would populate the wrong
          // cache entry and the loading branch would still fetch via the override key.
          const overrideIdx = ctx.partialFirstText !== null ? ctx.partialFirstParagraphIndex : null
          for (let i = 0; i < paragraphs.length; i++) {
            if (i === overrideIdx) continue
            const p = paragraphs[i]
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

    // --- 2b. navStore -> player: external page navigation ---
    // When the EPUB rendition starts navigating (curl gesture or arrow
    // button), navStore.navState leaves 'idle' *synchronously* inside the
    // click handler — well before the 200 ms curl animation completes and
    // long before PARAGRAPHS_UPDATED arrives. We use this signal to:
    //   1. Pause audio NOW so the old page doesn't bleed into the curl.
    //   2. Tell the machine via PAGE_NAVIGATING so it transitions out of
    //      playing/loading/paused into the new `pageNavigating` state and
    //      remembers whether to auto-resume on the new page.
    const unsubNav = useNavStore.subscribe(
      (s) => s.navState,
      (navState, prevNavState) => {
        if (prevNavState === 'idle' && navState !== 'idle') {
          stopAudio()
          // Clear the highlight immediately so the UI doesn't keep the old
          // paragraph highlighted during the curl.
          usePlayerStore.setState({ activeParagraph: null })
          // When the player itself requested the nav (waitingForParagraphs
          // → pageRequest), the request type tells us the direction. Read it
          // BEFORE EpubView's tryConsumePageRequest clears it (subscribers
          // fire synchronously inside navMachine.send, before the clear).
          // For external nav (user clicked the EPUB arrow), pageRequest is
          // null and we default to 'forward' so the player lands on paragraph
          // 0 of the new page.
          const pageRequest = usePlayerStore.getState().pageRequest
          const direction: 'forward' | 'backward' = pageRequest === 'prev' ? 'backward' : 'forward'
          actor.send({ type: 'PAGE_NAVIGATING', direction })
        }
        // Nav completed (returned to idle). In the success path, the
        // rendition fired `relocated` during r.next() which already pushed
        // PARAGRAPHS_UPDATED into the machine — so by now we're in
        // `loading` or beyond. If we are STILL in `pageNavigating`, the
        // rendition either didn't navigate at all (epubjs No Section Found,
        // end of book, transient error) or fired `relocated` with the same
        // location. The player would otherwise wait 10s for the timeout —
        // republish the current view immediately so the user recovers fast.
        if (prevNavState !== 'idle' && navState === 'idle') {
          if (mapStateValue(actor.getSnapshot().value) === 'pageNavigating') {
            publishCurrentEpubParagraphs()
          }
        }
      }
    )

    // --- 3. Machine actions -> audio side effects ---
    let prevState = ''
    // Generation counter to cancel stale fetches when a new loading entry fires
    let fetchGeneration = 0
    const audioUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const paragraph = ctx.currentParagraphs[ctx.paragraphIndex] as
        | (typeof ctx.currentParagraphs)[number]
        | undefined

      if (state === 'loading') {
        // Silence the previous page's audio immediately so it doesn't bleed
        // into the new page while the next TTS fetch is in flight.
        stopAudio()
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

      if (state === 'stopped' && prevState !== 'stopped' && prevState !== 'idle') {
        stopAudio()
        usePlayerStore.setState({
          activeParagraph: null
        })
      }

      if (state === 'waitingForParagraphs') {
        stopAudio()
        const direction = actor.getSnapshot().context.direction
        usePlayerStore.setState({
          pageRequest: direction === 'backward' ? 'prev' : 'next'
        })
      }

      if (state === 'republishingParagraphs') {
        stopAudio()
        // Do NOT set pageRequest — the player has not asked for a new page.
        // Re-read the rendition's current view and republish its paragraphs so
        // the machine can proceed to loading.
        publishCurrentEpubParagraphs()
      }

      // pageNavigating: external nav already in flight. Just silence audio
      // and clear the highlight. Do NOT set pageRequest — the rendition is
      // already curling and another request would double-navigate.
      if (state === 'pageNavigating') {
        stopAudio()
        usePlayerStore.setState({ activeParagraph: null })
      }

      if (state === 'idle' && prevState !== 'idle') {
        cleanupAudio(bookId)
        usePlayerStore.setState({
          activeParagraph: null,
          errors: [],
          pageRequest: null
        })
      }

      prevState = state
    })

    // --- 4. Machine send wiring ---
    const send: PlayerSend = actor.send
    sendRef.current = send
    usePlayerStore.getState().setSend(send)

    // --- 5. AudioElement -> machine callbacks ---
    const handleEnded = () => {
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
    const pdfPageData = pdfState.pageNumberToPageData[pdfState.pageNumber] as
      | (typeof pdfState.pageNumberToPageData)[number]
      | undefined
    if (pdfPageData) {
      // Convert text content items to paragraphs
      const items = pdfPageData.items
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
      unsubNav()
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

async function loadAndPlayAudio(blobUrl: string, isCancelled?: () => boolean): Promise<void> {
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
