// apps/electron/src/renderer/src/hooks/usePlayerMachine.ts
//
// Composition layer that wires the playerMachine actor to its side-effect
// adapters. After Phase 3.3 the audio I/O is owned by an invoked
// `audioActor` inside playerMachine itself; this hook only handles:
//   - actor lifecycle (create, INITIALIZE, CLEANUP)
//   - machine→store sync (playingState, activeParagraph, errors)
//   - store→machine paragraph sync with deep-equality + prefetch
//   - navStore→machine PAGE_NAVIGATING bridge (until Phase 3.4 collapses it)
//   - PDF seed-on-mount + resume-paragraph DB writes
//
// The orchestration bridge stays for now — Phase 3.4 swaps it for the
// view-actor wiring once playerMachine invokes the view actors directly.
import { useEffect, useMemo, useRef } from 'react'
import { createActor, type AnyActorLogic } from 'xstate'
import { playerMachine, type TtsFetcher } from '@/machines/playerMachine'
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
import { audioElement } from '@/actors/audioActor'
import { wireOrchestrationBridge } from '@/hooks/playerOrchestrationBridge'

export type UsePlayerMachineOptions = {
  /**
   * Per-format view actor logic. Provided by the format reader (EpubView →
   * epubViewActor, pdf.tsx → pdfViewActor). The hook overrides the machine's
   * placeholder `view` actor via `.provide({ actors: { view: viewLogic } })`
   * so the invoked actor can drive rendition.next() / page navigation and
   * emit VIEW_CHANGED back to the machine. When omitted, the noop placeholder
   * remains and NAVIGATE_* sends from the machine are dropped — fine for
   * formats that don't trigger view-boundary advances during TTS (azw3/mobi
   * seed all paragraphs at chapter-load time).
   */
  viewLogic?: AnyActorLogic
  /**
   * Format-specific input forwarded to the invoked view actor. Shape depends
   * on viewLogic (EpubViewInput for epub, PdfViewInput for pdf). Carried as
   * unknown because the hook itself is format-agnostic.
   */
  viewInput?: unknown
}

// Re-exported for existing consumers (E2E testing helpers, services that
// inject the singleton). The actual ownership lives in actors/audioActor.
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

export function usePlayerMachine(bookId: string, options?: UsePlayerMachineOptions) {
  const actorRef = useRef<ReturnType<typeof createActor<typeof playerMachine>> | null>(null)
  const sendRef = useRef<PlayerSend>(() => {})

  // Customise the machine when a per-format view actor is provided. Memo on
  // viewLogic identity so EpubView/pdf.tsx can stabilise it with their own
  // useMemo without churning the actor lifecycle.
  const machine = useMemo(
    () =>
      options?.viewLogic
        ? playerMachine.provide({ actors: { view: options.viewLogic } })
        : playerMachine,
    [options?.viewLogic]
  )

  useEffect(() => {
    // Create and start the machine actor. The fetcher input is bound here so
    // playerMachine's invoked fetchTtsLogic talks to the real TTS service in
    // production; tests rely on the machine's default noopFetcher and never
    // wait for a real fetch to resolve.
    const ttsFetcher: TtsFetcher = (req) => getTtsService().requestAudio(req)
    const actor = createActor(machine, {
      input: { fetcher: ttsFetcher, viewInput: options?.viewInput }
    })
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
          // Audio is silenced by the machine's pageNavigating entry action
          // (sendTo audio STOP). Just send PAGE_NAVIGATING and clear the
          // highlight so the UI doesn't keep the old paragraph marked
          // during the curl.
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
        // location. publishCurrentEpubParagraphs validates that the new
        // view differs from what's already in playerStore; if not, we
        // send NAV_NO_PROGRESS so the machine transitions to stopped
        // immediately instead of timing out or — the original bug —
        // looping back to paragraph 0 of the OLD view via a republish of
        // its own paragraphs.
        if (prevNavState !== 'idle' && navState === 'idle') {
          if (mapStateValue(actor.getSnapshot().value) === 'pageNavigating') {
            const published = publishCurrentEpubParagraphs()
            if (!published) {
              actor.send({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
            }
          }
        }
      }
    )

    // --- 3. Side-effect bridge (orchestration only — audio moved to actor) ---
    //
    // The audio I/O bridge has been replaced by an invoked audioActor inside
    // playerMachine (Phase 3.3). What remains here is cross-system
    // orchestration: clearing activeParagraph on visual interruption,
    // setting pageRequest on waitingForParagraphs, and triggering
    // publishCurrentEpubParagraphs on republishingParagraphs. Phase 3.4
    // replaces these by invoking per-format view actors.
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
      teardownOrchestration()
      unsubCurrent()
      unsubNext()
      unsubPrev()
      unsubNav()
      // Cancel any in-flight or pending TTS requests for this book. Audio is
      // already silenced by CLEANUP → idle (sendTo audio CLEAR_SRC).
      getTtsService().cancelBookRequests(bookId)
      usePlayerStore.getState().setSend(() => {})
      actor.stop()
      actorRef.current = null
    }
  }, [bookId, machine, options?.viewInput])

  return {
    // Why: sendRef.current holds the stable wrapped send function created in useEffect; callers consume the returned object synchronously. The ref's identity is stable across renders; only its current value swaps when the actor is recreated.
    // eslint-disable-next-line react-hooks/refs
    send: sendRef.current
  }
}

// Audio helpers used to live here, then moved to playerAudioBridge.ts in
// Phase 2, then to actors/audioActor.ts in Phase 3.3. The bridge file was
// deleted; future readers grep'ing for stopAudio/loadAndPlayAudio land here.
