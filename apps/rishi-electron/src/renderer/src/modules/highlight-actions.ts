import {
  saveHighlight,
  deleteHighlight,
  getHighlightsForBook,
  type HighlightRow
} from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import { NOTE_COLOR_NONE, type HighlightColor } from '@/types/highlight'

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

export interface SaveNoteOnlyArgs {
  bookSyncId: string
  cfiRange: string
  text: string
}

/**
 * Create a note-only highlight row (no SVG mark, just an anchor for a note).
 * Persists via `saveHighlight` with `color: 'none'`, then backfills the
 * canonical row (with its DB-assigned id) via `getHighlightsForBook`.
 *
 * Unlike `applyHighlightWithUndo`, this has no undo handle and no visual
 * side-effects — opening the NoteEditor on the returned row IS the user-
 * facing confirmation. Adding undo here would surface a toast for a flow
 * where there is nothing visually destructive to undo.
 */
export async function saveNoteOnly(args: SaveNoteOnlyArgs): Promise<HighlightRow> {
  const { bookSyncId, cfiRange, text } = args

  await saveHighlight({ bookSyncId, cfiRange, text, color: NOTE_COLOR_NONE })
  getSyncService().triggerWrite()

  const rows = await getHighlightsForBook(bookSyncId)
  const fresh = rows.find((r) => r.cfiRange === cfiRange)
  if (!fresh) {
    throw new Error(`[saveNoteOnly] persisted row not found for cfiRange ${cfiRange}`)
  }
  return fresh
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
