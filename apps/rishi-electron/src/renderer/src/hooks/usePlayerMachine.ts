// apps/electron/src/renderer/src/hooks/usePlayerMachine.ts
//
// Composition layer that wires the playerMachine actor to its side-effect
// adapters. The audio and orchestration concerns live in dedicated bridges
// (see playerAudioBridge.ts, playerOrchestrationBridge.ts). This file's
// responsibility is reduced to: actor lifecycle, machine→store sync,
// store→machine paragraph sync, navStore→machine PAGE_NAVIGATING bridge,
// PDF seed-on-mount, and resume-paragraph DB writes.
import { useEffect, useRef } from 'react'
import { createActor } from 'xstate'
import { playerMachine } from '@/machines/playerMachine'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex, PlayerStoreState, PlayerSend } from '@/stores/playerStore'
import { useNavStore } from '@/stores/navStore'
import { getTtsService } from '@/services'
import { getVisualCueEmitter, resolveParagraphElement } from '@/services/tts'
import { usePdfStore } from '@/stores/pdfStore'
import isEqual from 'fast-deep-equal'
import type { TextItem, TextMarkedContent } from 'react-pdf'
import { updateBookLastParagraph } from '@/lib/api'
import { publishCurrentEpubParagraphs } from '@/stores/epubStore'
import { audioElement, stopAudio, wireAudioBridge } from '@/hooks/playerAudioBridge'
import { wireOrchestrationBridge } from '@/hooks/playerOrchestrationBridge'

// Re-exported for existing consumers (E2E testing helpers, services that
// inject the singleton). The actual ownership lives in playerAudioBridge.
export { audioElement }

// Map XState machine state value to PlayerStoreState string
function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  // Compound state: { paused: "clean" } -> "paused.clean"
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

export function startResumeWriteSubscription({ bookId }: { bookId: number }): {
  dispose: () => void
  flush: () => void
} {
  let pendingId: string | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const writeNow = (id: string): void => {
    void updateBookLastParagraph({ bookId, lastParagraph: id }).catch((err: unknown) => {
      console.warn('[player] resume-paragraph save failed:', err)
    })
  }

  const flush = (): void => {
    if (timer === null || pendingId === null) return
    clearTimeout(timer)
    const id = pendingId
    timer = null
    pendingId = null
    writeNow(id)
  }

  const unsub = usePlayerStore.subscribe(
    (s) => s.activeParagraph,
    (active) => {
      if (active === null) return
      usePlayerStore.setState({ lastPlayedParagraphIndex: active.index })
      pendingId = active.index
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        const id = pendingId
        timer = null
        pendingId = null
        if (id !== null) writeNow(id)
      }, 500)
    }
  )

  const dispose = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
    pendingId = null
    unsub()
  }

  return { dispose, flush }
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
        const idx = currentParagraphs.findIndex((p) => p.index === nextActive.index)
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

    // --- 3. Side-effect bridges ---
    //
    // Audio I/O and store-orchestration are both driven off the same actor
    // state stream, but the concerns are independent. They live in dedicated
    // adapters so each can be tested and (in Phase 3 of the rewrite plan)
    // swapped for an xstate `fromCallback` actor without touching the other.
    const teardownAudio = wireAudioBridge(actor, bookId)
    const teardownOrchestration = wireOrchestrationBridge(actor)

    // --- 4. Machine send wiring ---
    const send: PlayerSend = actor.send
    sendRef.current = send
    usePlayerStore.getState().setSend(send)

    // --- Start actor and initialize ---
    actor.start()
    // Seeded by routes/books.$id.lazy.tsx before this hook initializes.
    const resumeParagraphIndex = usePlayerStore.getState().lastPlayedParagraphIndex
    actor.send({ type: 'INITIALIZE', bookId, resumeParagraphIndex })

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

    // Persist the live paragraph id so reopen can highlight + resume.
    // bookId is a string in this hook (xstate context expects string ids);
    // the DB column is keyed by numeric book id.
    const resumeWrite = startResumeWriteSubscription({ bookId: Number(bookId) })

    return () => {
      resumeWrite.flush()
      resumeWrite.dispose()
      actor.send({ type: 'CLEANUP' })
      machineUnsub.unsubscribe()
      teardownAudio()
      teardownOrchestration()
      unsubCurrent()
      unsubNext()
      unsubPrev()
      unsubNav()
      usePlayerStore.getState().setSend(() => {})
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

// Audio helpers used to live here; they now live in playerAudioBridge.ts.
// Keeping this footer-comment so a future reader who greps for stopAudio /
// loadAndPlayAudio in this file lands on the relocation note.
