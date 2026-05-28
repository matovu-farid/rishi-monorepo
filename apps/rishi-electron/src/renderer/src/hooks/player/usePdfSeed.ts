// apps/electron/src/renderer/src/hooks/player/usePdfSeed.ts
//
// One-shot seed when the actor first becomes available: convert the active PDF
// page's TextItems into paragraphs, write them to playerStore, then forward
// whatever is already in playerStore to the machine via PARAGRAPHS_UPDATED.
import { useEffect } from 'react'
import type { TextItem, TextMarkedContent } from 'react-pdf'
import { usePdfStore } from '@/stores/pdfStore'
import { usePlayerStore } from '@/stores/playerStore'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

export function usePdfSeed(actor: PlayerActor | null): void {
  useEffect(() => {
    if (!actor) return
    const pdfState = usePdfStore.getState()
    const pdfPageData = pdfState.pageNumberToPageData[pdfState.pageNumber] as
      | (typeof pdfState.pageNumberToPageData)[number]
      | undefined
    if (pdfPageData) {
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

    const currentParagraphs = usePlayerStore.getState().currentParagraphs
    if (currentParagraphs.length > 0) {
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: currentParagraphs })
    }
  }, [actor])
}
