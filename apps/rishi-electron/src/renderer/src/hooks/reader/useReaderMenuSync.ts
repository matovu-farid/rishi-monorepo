import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'

type ElectronMenuBridge = {
  send: (channel: string, payload: unknown) => void
  setMenuContext: (ctx: Record<string, unknown>) => void
}

/**
 * Single typed accessor for the electron menu bridge. Keeps the
 * `window as unknown as` casts confined to one place so the rest of the hook
 * reads naturally and the cast surface is auditable.
 */
function getElectron(): ElectronMenuBridge {
  return (window as unknown as { electron: ElectronMenuBridge }).electron
}

/**
 * Mirror reader state into the native menu:
 *  - publish the current book title (so the Window menu shows it),
 *  - mirror the TOC sheet open/closed state into the menu context,
 *  - mirror the TTS play state into the menu context so the
 *    Reader > Read Aloud label flips while playing.
 *
 * Extracted from the duplicated effects in EpubView / MobiView / Azw3View.
 */
export function useReaderMenuSync({
  book,
  tocOpen
}: {
  book: { id: number; title: string }
  tocOpen: boolean
}): void {
  // Publish title so the native Window menu sees the loaded book.
  useEffect(() => {
    const e = getElectron()
    e.send('window:setBookTitle', { bookId: book.id, title: book.title })
  }, [book.id, book.title])

  // Mirror TOC sheet state into the menu context.
  useEffect(() => {
    const e = getElectron()
    e.setMenuContext({ tocOpen })
  }, [tocOpen])

  // Mirror TTS play state so the Reader > Read Aloud label flips while playing.
  // We subscribe once and let the store push updates through.
  useEffect(() => {
    const e = getElectron()
    const unsub = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        e.setMenuContext({ isReading: state === 'playing' })
      }
    )
    e.setMenuContext({ isReading: usePlayerStore.getState().playingState === 'playing' })
    return unsub
  }, [])
}
