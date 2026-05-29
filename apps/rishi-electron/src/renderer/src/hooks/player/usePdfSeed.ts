// apps/electron/src/renderer/src/hooks/player/usePdfSeed.ts
//
// Kickstart for the PDF player: when the actor first mounts, forward
// whatever paragraphs `usePdfReader` has already published to
// playerStore.currentParagraphs into the machine as PARAGRAPHS_UPDATED.
// The pdfViewActor's own seed-on-mount fires too, but it lands in the
// machine's `idle` state (which discards PARAGRAPHS_UPDATED); this hook
// runs after INITIALIZE has transitioned the machine to `stopped`, which
// accepts the event and applies resume-index logic.
//
// Previously this hook ALSO built a synthetic per-TextItem paragraph list
// from pdfStore.pageNumberToPageData and wrote it to playerStore — racing
// with usePdfReader's canonical extractor and producing two different
// paragraph shapes (`pdf-N-idx` vs `${N * 10000 + i}`). Removed.
import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import { debugLog } from '@/utils/debugLog'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

export function usePdfSeed(actor: PlayerActor | null): void {
  useEffect(() => {
    if (!actor) return
    const currentParagraphs = usePlayerStore.getState().currentParagraphs
    debugLog('pdfSeed:run', {
      paragraphCount: currentParagraphs.length,
      firstIndex: currentParagraphs[0]?.index ?? null
    })
    if (currentParagraphs.length > 0) {
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: currentParagraphs })
    }
  }, [actor])
}
