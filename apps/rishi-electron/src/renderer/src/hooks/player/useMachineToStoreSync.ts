// apps/electron/src/renderer/src/hooks/player/useMachineToStoreSync.ts
//
// Mirrors machine snapshot → playerStore (playingState, activeParagraph,
// errors) and emits a visual cue when the active paragraph changes.
import { useEffect } from 'react'
import isEqual from 'fast-deep-equal'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex, PlayerStoreState } from '@/stores/playerStore'
import { getVisualCueEmitter, resolveParagraphElement } from '@/services/tts'
import { debugLog } from '@/utils/debugLog'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  // Compound state: { paused: "clean" } -> "paused.clean"
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

export function useMachineToStoreSync(actor: PlayerActor | null): void {
  useEffect(() => {
    if (!actor) return
    // Track the last currentParagraphs we wrote so we only mirror on value
    // change. Without this dedup the mirror fires on EVERY snapshot — including
    // the many transient assigns during a single state transition — and downstream
    // playerStore subscribers (e.g. UI components reading `currentParagraphs` as
    // a dep) would re-render needlessly. Zustand's subscribeWithSelector dedupes
    // for its own subscribers, but other consumers reading via the hook still
    // observe the setState event.
    let lastMirroredParagraphs: ParagraphWithIndex[] | null = null
    let lastLoggedState: PlayerStoreState | null = null
    const sub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value)
      const ctx = snapshot.context
      const currentParagraph: ParagraphWithIndex | null =
        ctx.currentParagraphs[ctx.paragraphIndex] ?? null

      // Log every distinct player-state value the machine settles into.
      // De-duped via lastLoggedState so the many transient transition ticks
      // (assigns, child invocations) don't flood the log with the same value.
      if (state !== lastLoggedState) {
        debugLog('player:state', {
          state,
          previousState: lastLoggedState,
          paragraphIndex: ctx.paragraphIndex,
          paragraphCount: ctx.currentParagraphs.length,
          firstCfi: ctx.currentParagraphs[0]?.index ?? null,
          direction: ctx.direction,
          wantsAutoResume: ctx.wantsAutoResume
        })
        lastLoggedState = state
      }

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

      // currentParagraphs mirror: the machine context is the SOLE source of
      // truth, sourced from the view actor's validated VIEW_CHANGED →
      // PARAGRAPHS_UPDATED → storeParagraphs path. Mirroring here (instead of
      // letting the epubStore subscription publish from a stale CFI) removes
      // the snap-back race: a mid-animation `relocated` with a stale CFI no
      // longer reaches playerStore.currentParagraphs because the view actor
      // rejects it via NAV_NO_PROGRESS before the machine context updates.
      //
      // Only update playerStore.currentParagraphs when ctx.currentParagraphs
      // ACTUALLY changes (deep equality), so we don't republish identical
      // arrays during every assign-driven snapshot tick.
      const paragraphsChanged =
        lastMirroredParagraphs === null ||
        !isEqual(lastMirroredParagraphs, ctx.currentParagraphs)
      if (paragraphsChanged) {
        debugLog('mirror:paragraphs', {
          state,
          paragraphIndex: ctx.paragraphIndex,
          paragraphCount: ctx.currentParagraphs.length,
          firstCfi: ctx.currentParagraphs[0]?.index ?? null,
          activeCfi: nextActive?.index ?? null,
          prevCount: lastMirroredParagraphs?.length ?? null,
          prevFirstCfi: lastMirroredParagraphs?.[0]?.index ?? null
        })
        lastMirroredParagraphs = ctx.currentParagraphs
        usePlayerStore.setState({
          playingState: state,
          currentParagraphs: ctx.currentParagraphs,
          activeParagraph: nextActive,
          errors: ctx.errors
        })
      } else {
        usePlayerStore.setState({
          playingState: state,
          activeParagraph: nextActive,
          errors: ctx.errors
        })
      }

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
    return () => sub.unsubscribe()
  }, [actor])
}
