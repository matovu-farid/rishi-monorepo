// apps/electron/src/renderer/src/hooks/playerOrchestrationBridge.ts
//
// State-driven cross-system orchestration for the player machine.
//
// What it owns:
//   - Clearing `usePlayerStore.activeParagraph` on transitions where the
//     visible highlight must drop (loading, stopped, waitingForParagraphs,
//     pageNavigating, idle).
//   - Setting `usePlayerStore.pageRequest` when the player enters
//     `waitingForParagraphs` so the epub rendition advances.
//     ⚠ This is the zustand-mediated signal that the Phase 3 actor-model
//     restructure removes entirely; centralising it here makes the future
//     deletion mechanical.
//   - Calling `publishCurrentEpubParagraphs()` when the machine enters
//     `republishingParagraphs`.
//     ⚠ This is the loop-back safety net flagged in the rewrite plan
//     (§1). Centralising it here marks the seam.
//   - Resetting transient store state (errors, pageRequest) on the
//     `idle` transition.
//
// What it explicitly does NOT own (lives in playerAudioBridge):
//   - Audio fetch / play / pause / stop.
//   - Forwarding 'ended' / 'error' from the audio element.
import type { createActor } from 'xstate'
import type { playerMachine } from '@/machines/playerMachine'
import { usePlayerStore } from '@/stores/playerStore'
import type { PlayerStoreState } from '@/stores/playerStore'
import { publishCurrentEpubParagraphs } from '@/stores/epubStore'

type PlayerActor = ReturnType<typeof createActor<typeof playerMachine>>

function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === 'string') return value as PlayerStoreState
  const [parent, child] = Object.entries(value)[0]
  return `${parent}.${child}` as PlayerStoreState
}

/**
 * Wire the playerMachine actor's state stream to cross-system signals
 * (player store mutations + the epubStore re-publish trigger).
 *
 * Returns a teardown that unsubscribes the actor.
 */
export function wireOrchestrationBridge(actor: PlayerActor): () => void {
  let prevState = ''

  const unsub = actor.subscribe((snapshot) => {
    const state = mapStateValue(snapshot.value)

    // Clear the visible highlight on transitions where playback is
    // interrupted or the active paragraph is no longer authoritative.
    if (state === 'loading') {
      usePlayerStore.setState({ activeParagraph: null })
    }

    if (state === 'stopped' && prevState !== 'stopped' && prevState !== 'idle') {
      usePlayerStore.setState({ activeParagraph: null })
    }

    if (state === 'waitingForParagraphs') {
      // The machine is asking for the next/prev page's paragraphs.
      // Direction is whatever the machine set on entry (forward / backward).
      const direction = snapshot.context.direction
      usePlayerStore.setState({
        pageRequest: direction === 'backward' ? 'prev' : 'next'
      })
    }

    if (state === 'republishingParagraphs') {
      // Do NOT set pageRequest — the player has not asked for a new page.
      // Re-read the rendition's current view and republish its paragraphs.
      // publishCurrentEpubParagraphs returns false when the new view is
      // image-only OR byte-for-byte identical to the paragraphs already in
      // playerStore (end-of-book / drift restore). In that case we send
      // NAV_NO_PROGRESS so the machine transitions to `stopped` — without
      // this the republish-of-same-paragraphs case would loop back to
      // paragraph 0 of the OLD view. This encodes the same validation rule
      // as actors/epubViewActor.ts; Phase 3.4 final-form wires the actor
      // directly and this safety-net path gets deleted.
      const published = publishCurrentEpubParagraphs()
      if (!published) {
        actor.send({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
      }
    }

    if (state === 'pageNavigating') {
      usePlayerStore.setState({ activeParagraph: null })
    }

    if (state === 'idle' && prevState !== 'idle') {
      usePlayerStore.setState({
        activeParagraph: null,
        errors: [],
        pageRequest: null
      })
    }

    prevState = state
  })

  return () => {
    unsub.unsubscribe()
  }
}
