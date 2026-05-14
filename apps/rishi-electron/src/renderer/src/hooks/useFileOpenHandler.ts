import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { getBookImportService } from '@/services'

/**
 * Handles files opened via the OS "Open With" menu. The main process
 * forwards paths on the `open-files` channel (and buffers any that arrive
 * before this listener subscribes — drained via `getPendingOpenFiles`).
 */
export function useFileOpenHandler(): void {
  const queryClient = useQueryClient()
  // Guards against overlapping batches when multiple files are double-clicked
  // in quick succession — the importer isn't reentrant per filepath.
  const inFlight = useRef(false)

  useEffect(() => {
    const importPaths = async (paths: string[]): Promise<void> => {
      if (paths.length === 0 || inFlight.current) return
      inFlight.current = true
      try {
        const svc = getBookImportService()
        const results = await svc.importBatch(paths)
        await queryClient.invalidateQueries({ queryKey: ['books'] })
        let firstSuccess: number | null = null
        for (const r of results) {
          if (!r.ok) {
            toast.error(`Failed to import: ${r.error}`)
          } else {
            firstSuccess ??= r.bookId
          }
        }
        if (firstSuccess !== null) {
          // Phase 3: each book lives in its own BrowserWindow. Ask the main
          // process to spawn one rather than navigating the library window.
          void (
            window as unknown as { electron: { openBook(id: number): Promise<void> } }
          ).electron.openBook(firstSuccess)
        }
      } finally {
        // Why: This is the canonical mutex pattern (check-then-set + release in finally); the await above releases the loop but inFlight.current can only be true if THIS invocation set it on line 20, so no other concurrent writer can race.
        // eslint-disable-next-line require-atomic-updates
        inFlight.current = false
      }
    }

    const unsubscribe = window.electron.on('open-files', (...args: unknown[]) => {
      const paths = args[0]
      if (Array.isArray(paths)) void importPaths(paths as string[])
    })

    void window.electron
      .getPendingOpenFiles()
      .then((paths) => importPaths(paths))
      .catch(() => {})

    return () => {
      unsubscribe()
    }
  }, [queryClient])
}
