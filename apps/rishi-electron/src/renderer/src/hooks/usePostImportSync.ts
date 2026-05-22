import { useEffect } from 'react'
import { toast } from 'sonner'
import { getBookImportService, getSyncService } from '@/services'

/**
 * Cross-cutting wiring for the book-import progress stream:
 *
 *   - `done`           → fire-and-forget sync push so the new row is visible
 *                        on other devices immediately (no 5-min wait).
 *   - `upload-failed`  → surface a toast. Storage-cap errors come through
 *                        with a user-readable message from
 *                        modules/file-sync.ts UploadLimitError.
 *
 * Hoisted out of `__root.tsx` so it can be unit-tested without mounting the
 * full router tree. The real wiring lives at app root (single listener per
 * window) — do NOT add this hook elsewhere.
 */
export function usePostImportSync(): void {
  useEffect(() => {
    return getBookImportService().onImportProgress((event) => {
      if (event.kind === 'done') {
        const e = (window as unknown as { electron?: { refreshMenu?(): void } }).electron
        e?.refreshMenu?.()
        try {
          getSyncService().triggerWrite()
        } catch (err) {
          console.warn('[import] post-import sync trigger failed', err)
        }
      } else if (event.kind === 'upload-failed') {
        toast.error('Sync upload failed', { description: event.error })
      }
    })
  }, [])
}
