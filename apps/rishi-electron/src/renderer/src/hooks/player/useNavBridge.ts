// apps/electron/src/renderer/src/hooks/player/useNavBridge.ts
//
// navStore → player bridge for external page navigation. When the EPUB
// rendition starts navigating (curl gesture or arrow button), navStore.navState
// leaves 'idle' synchronously inside the click handler — well before the 200 ms
// curl animation completes and long before PARAGRAPHS_UPDATED arrives. The
// player is told via PAGE_NAVIGATING so it transitions out of playing/loading/
// paused into the new `pageNavigating` state. The view actor (epubViewActor)
// owns new-view validation: same-CFI / image-only relocations emit
// NAV_NO_PROGRESS directly instead of the old publish-then-detect path.
import { useEffect } from 'react'
import { useNavStore } from '@/stores/navStore'
import { usePlayerStore } from '@/stores/playerStore'
import { debugLog } from '@/utils/debugLog'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

export function useNavBridge(actor: PlayerActor | null): void {
  useEffect(() => {
    if (!actor) return
    const unsub = useNavStore.subscribe(
      (s) => s.navState,
      (navState, prevNavState) => {
        debugLog('navBridge:navState', {
          prevNavState,
          navState,
          playerState: actor.getSnapshot().value,
          direction: actor.getSnapshot().context.direction
        })
        if (prevNavState === 'idle' && navState !== 'idle') {
          // Audio is silenced by the machine's pageNavigating entry action
          // (sendTo audio STOP). Just send PAGE_NAVIGATING and clear the
          // highlight so the UI doesn't keep the old paragraph marked
          // during the curl.
          usePlayerStore.setState({ activeParagraph: null })
          // The machine owns direction state; the view actor sets it when
          // it issues NAVIGATE_PREV. For external nav (user clicked the EPUB
          // arrow) the machine's stored direction is whatever was last set,
          // defaulting to 'forward' — which is the correct behaviour for a
          // forward-arrow click and an acceptable fallback otherwise.
          const direction: 'forward' | 'backward' = actor.getSnapshot().context.direction
          actor.send({ type: 'PAGE_NAVIGATING', direction })
        }
      }
    )
    return () => unsub()
  }, [actor])
}
