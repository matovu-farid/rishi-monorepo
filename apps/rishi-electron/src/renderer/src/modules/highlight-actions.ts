import { saveHighlight, deleteHighlight, saveHighlightPdf, deleteHighlightById, type PdfLocator } from '@/modules/highlight-storage'
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

export interface ApplyHighlightPdfArgs {
  target: HighlightTarget
  bookSyncId: string
  locator: PdfLocator
  text: string
  color: HighlightColor
}

export async function applyHighlightWithUndoPdf(
  args: ApplyHighlightPdfArgs
): Promise<HighlightHandle> {
  await args.target.applyVisual()
  const id = await saveHighlightPdf({
    bookSyncId: args.bookSyncId,
    locator: args.locator,
    text: args.text,
    color: args.color
  })
  return {
    undo: async () => {
      await args.target.removeVisual()
      await deleteHighlightById(id)
    }
  }
}

export interface DeleteHighlightArgs {
  target: HighlightTarget
  bookSyncId: string
  cfiRange: string
  text: string
  color: HighlightColor
  note?: string
  chapter?: string | null
}

/**
 * Delete a highlight optimistically and return a handle whose `undo()`
 * re-applies the visual mark and re-inserts the row via saveHighlight.
 * Errors during persistence are logged but never block the handle.
 *
 * Note: the underlying `highlights:save` IPC ignores soft-deleted rows in
 * its upsert check, so undo inserts a FRESH row; the soft-deleted ghost
 * remains. Sync semantics stay correct (both rows carry `isDirty=1`).
 */
export async function deleteHighlightWithUndo(args: DeleteHighlightArgs): Promise<HighlightHandle> {
  const { target, bookSyncId, cfiRange, text, color, note, chapter } = args

  await target.removeVisual()

  try {
    await deleteHighlight(bookSyncId, cfiRange)
    getSyncService().triggerWrite()
  } catch (err) {
    console.warn('[highlight] delete failed:', err)
  }

  return {
    async undo() {
      await target.applyVisual()
      try {
        await saveHighlight({
          bookSyncId,
          cfiRange,
          text,
          color,
          note,
          chapter: chapter ?? undefined
        })
        getSyncService().triggerWrite()
      } catch (err) {
        console.warn('[highlight] re-save failed:', err)
      }
    }
  }
}
