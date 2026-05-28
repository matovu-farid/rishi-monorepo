// apps/electron/src/renderer/src/hooks/player/useMachineToStoreSync.ts
//
// Mirrors machine snapshot → playerStore (playingState, activeParagraph,
// errors) and emits a visual cue when the active paragraph changes.
import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex, PlayerStoreState } from '@/stores/playerStore'
import { getVisualCueEmitter, resolveParagraphElement } from '@/services/tts'
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
    const sub = actor.subscribe((snapshot) => {
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
    return () => sub.unsubscribe()
  }, [actor])
}
