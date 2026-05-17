import { useCallback, useEffect, useState } from 'react'
import { getHighlightsForBook, type HighlightRow } from '@/modules/highlight-storage'

export interface UsePdfHighlightsResult {
  highlights: HighlightRow[]
  refresh: () => Promise<void>
  setHighlights: React.Dispatch<React.SetStateAction<HighlightRow[]>>
}

/**
 * Loads and tracks PDF-format highlights for a book.
 *
 * Important: `bookSyncId` is the IPC-fetched sync_id (via
 * `window.electron.booksGetSyncId`), NOT the prop `book.syncId` which is
 * frequently undefined when PdfView mounts. Passing the wrong source here
 * causes highlights to silently never load or save.
 */
export function usePdfHighlights(bookSyncId: string): UsePdfHighlightsResult {
  const [highlights, setHighlights] = useState<HighlightRow[]>([])

  const refresh = useCallback(async (): Promise<void> => {
    if (!bookSyncId) return
    const rows = await getHighlightsForBook(bookSyncId)
    setHighlights(rows.filter((r) => r.format === 'pdf'))
  }, [bookSyncId])

  useEffect(() => {
    let active = true
    if (!bookSyncId) return
    void getHighlightsForBook(bookSyncId).then((rows) => {
      if (!active) return
      setHighlights(rows.filter((r) => r.format === 'pdf'))
    })
    return () => {
      active = false
    }
  }, [bookSyncId])

  return { highlights, refresh, setHighlights }
}
