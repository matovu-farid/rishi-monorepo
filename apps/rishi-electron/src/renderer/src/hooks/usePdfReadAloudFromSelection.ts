import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import { buildPartialFirst } from '@/modules/read-aloud-from'

export interface UsePdfReadAloudFromSelectionParams {
  /**
   * Wraps the action with premium-feature auth gating (matches the
   * EpubView pattern where `requireAuth('tts', () => ...)` is used).
   */
  requireAuth: (feature: string, action: () => void) => void
}

/**
 * Bridges the native context-menu IPC `reader:readAloudFromSelection` to
 * the player store for PDF books. On fire, reads the live selection, finds
 * the paragraph whose text contains the selection (string match — robust
 * to PDF coord/zoom variations), and dispatches PLAY_FROM via the same
 * machine event EPUB uses.
 *
 * Char offset within the matched paragraph is determined by
 * `paragraph.text.indexOf(selectionText)`; sentence-start refinement is
 * delegated to `buildPartialFirst`. This keeps the implementation simple
 * and avoids fragile coord-math against the PDF text layer.
 */
export function usePdfReadAloudFromSelection(params: UsePdfReadAloudFromSelectionParams): void {
  const { requireAuth } = params

  useEffect(() => {
    const unsubscribe = window.electron.on('reader:readAloudFromSelection', () => {
      const text = window.getSelection()?.toString()?.trim() ?? ''
      if (!text) return

      const playingState = usePlayerStore.getState().playingState
      if (playingState === 'idle' || playingState === 'pageNavigating') return

      const paragraphs = usePlayerStore.getState().currentParagraphs
      if (paragraphs.length === 0) return

      // First paragraph whose text contains the selection. The selection
      // could span a paragraph boundary; in that case we start playback
      // from whichever paragraph holds the beginning of the selection.
      const probe = text.length > 50 ? text.slice(0, 50) : text
      const matchedIdx = paragraphs.findIndex((p) => p.text.includes(probe))
      if (matchedIdx === -1) return

      const para = paragraphs[matchedIdx]
      const charOffset = Math.max(0, para.text.indexOf(probe))

      const send = usePlayerStore.getState().send
      if (!send) return

      requireAuth('tts', () => {
        const { partialFirstText, partialFirstKey } = buildPartialFirst(
          para.index,
          para.text,
          charOffset
        )
        send({
          type: 'PLAY_FROM',
          paragraphIndex: matchedIdx,
          partialFirstText,
          partialFirstKey
        })
      })
    })
    return unsubscribe
  }, [requireAuth])
}
