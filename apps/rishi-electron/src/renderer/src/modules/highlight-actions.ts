import { saveHighlight, deleteHighlight } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import type { HighlightColor } from '@/types/highlight'

/**
 * The visual side of a highlight — apply and remove. Injected so this
 * module does not depend on epubjs (or any future format's renderer).
 */
export interface HighlightTarget {
  applyVisual: () => Promise<void> | void
  removeVisual: () => Promise<void> | void
}

export interface ApplyHighlightArgs {
  target: HighlightTarget
  bookSyncId: string
  cfiRange: string
  text: string
  color: HighlightColor
}

export interface HighlightHandle {
  undo: () => Promise<void>
}

/**
 * Apply a highlight optimistically and return a handle whose `undo()`
 * removes both the visual mark and the persisted row. Save errors are
 * logged but do not prevent the handle from being returned — the on-screen
 * mark is already drawn, so undo must still be able to remove it.
 */
export async function applyHighlightWithUndo(args: ApplyHighlightArgs): Promise<HighlightHandle> {
  const { target, bookSyncId, cfiRange, text, color } = args

  await target.applyVisual()

  try {
    await saveHighlight({ bookSyncId, cfiRange, text, color })
    getSyncService().triggerWrite()
  } catch (err) {
    console.warn('[highlight] save failed:', err)
  }

  return {
    async undo() {
      await target.removeVisual()
      try {
        await deleteHighlight(bookSyncId, cfiRange)
        getSyncService().triggerWrite()
      } catch (err) {
        console.warn('[highlight] delete failed:', err)
      }
    }
  }
}
