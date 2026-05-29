// apps/electron/src/renderer/src/hooks/player/useParagraphSubscriptions.ts
//
// Forwards playerStore paragraph slices → machine via PARAGRAPHS_UPDATED /
// NEXT_PARAGRAPHS_UPDATED / PREV_PARAGRAPHS_UPDATED, with deep equality so
// reference-different but content-identical arrays don't interrupt playback
// (playing → loading). Also prefetches TTS for current/next slices while
// playing or loading.
import { useEffect } from 'react'
import isEqual from 'fast-deep-equal'
import { usePlayerStore, type PlayerStoreState } from '@/stores/playerStore'
import { getTtsService } from '@/services'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

export function useParagraphSubscriptions(actor: PlayerActor | null, bookId: string): void {
  useEffect(() => {
    if (!actor) return
    const unsubCurrent = usePlayerStore.subscribe(
      (s) => s.currentParagraphs,
      (paragraphs) => {
        // Skip the PARAGRAPHS_UPDATED send when the change came from our own
        // mirror in useMachineToStoreSync (machine ctx → store). Without this
        // check we'd ping-pong: ctx changes → mirror writes store → this
        // subscription fires → PARAGRAPHS_UPDATED back to machine → ctx changes
        // again (no-op via deep equality, but the event still fires through
        // every transient state). Real external writers (e.g., a test that
        // calls setCurrentParagraphs) bypass this guard because their value
        // differs from ctx by definition.
        const ctx = actor.getSnapshot().context
        if (!isEqual(paragraphs, ctx.currentParagraphs)) {
          actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
        }
        // Only prefetch when player is actively playing/loading
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
    return () => {
      unsubCurrent()
      unsubNext()
      unsubPrev()
    }
  }, [actor, bookId])
}
