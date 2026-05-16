import { useEffect, useRef, useState, type RefObject } from 'react'
import { publishBookmarksToMenu } from '@/modules/bookmark-storage'

/**
 * Resolve a book's stable sync id from the main process and keep both a state
 * value (for render-time consumption) and a ref (for use inside callbacks)
 * in sync. When the sync id becomes non-empty, the menu's bookmark list is
 * published so the native Bookmarks menu reflects this book.
 *
 * This hook is shared by every reader view (EPUB / MOBI / AZW3) — they each
 * had the same effect inlined before this extraction.
 *
 * @param bookId numeric primary key from the local books table
 * @returns `bookSyncId` (state, '' until resolved) and `bookSyncIdRef`
 *   (the latest value, safe to read inside callbacks without triggering
 *   re-renders or `react-hooks/exhaustive-deps` noise)
 */
export function useBookSyncId(bookId: number): {
  bookSyncId: string
  bookSyncIdRef: RefObject<string | null>
} {
  const bookSyncIdRef = useRef<string | null>(null)
  const [bookSyncId, setBookSyncId] = useState<string>('')

  useEffect(() => {
    void window.electron.booksGetSyncId(bookId).then((syncId) => {
      bookSyncIdRef.current = syncId
      if (syncId) {
        setBookSyncId(syncId)
      }
    })
  }, [bookId])

  useEffect(() => {
    if (!bookSyncId) return
    void publishBookmarksToMenu(bookSyncId)
  }, [bookSyncId])

  return { bookSyncId, bookSyncIdRef }
}
