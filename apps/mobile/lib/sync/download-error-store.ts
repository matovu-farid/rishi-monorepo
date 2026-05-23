/**
 * DAT-003 — failed-download recovery store.
 *
 * Surfaces *post-fetch* download failures (i.e. the presigned-URL GET
 * succeeded, bytes are on disk in a `.tmp` file, but the atomic
 * `tmpFile.move()` into the final destination failed) to UI consumers so
 * a retry affordance can be rendered.
 *
 * Why a separate store from `upload-error-store`:
 *  - Different lifecycle: uploads fail BEFORE the file is in our possession
 *    (R2 PUT rejection); downloads here fail AFTER bytes have been fetched
 *    and need a local-filesystem retry, not a network retry.
 *  - Different UI: uploads use a transient snackbar; downloads need a
 *    persistent list (the user may dismiss the snackbar and come back
 *    later, the failed-download list should still be available).
 *
 * The store is the bridge between `downloadBookFile` (non-React caller)
 * and any subscriber that wants to render the retry list — the sync
 * status indicator, the library screen, or a future dedicated panel.
 */
import { create } from 'zustand'

export interface DownloadFailure {
  bookId: string
  r2Key: string
  format: 'epub' | 'pdf' | 'mobi' | 'djvu'
  /** Human-readable error message — surfaced verbatim in diagnostics. */
  reason: string
  /** Unix ms timestamp of when the failure was recorded. */
  failedAt: number
}

interface DownloadErrorState {
  failures: DownloadFailure[]
  /**
   * Record a failed download. If a failure already exists for the same
   * `bookId`, the existing entry is REPLACED rather than duplicated —
   * subsequent retries surface the most recent error context.
   */
  recordFailure: (input: {
    bookId: string
    r2Key: string
    format: DownloadFailure['format']
    reason: string
  }) => void
  /** Remove a single failed download (called after a successful retry). */
  clearFailure: (bookId: string) => void
  /** Empty the list (called on logout or hard reset). */
  clear: () => void
}

export const useDownloadErrorStore = create<DownloadErrorState>((set) => ({
  failures: [],
  recordFailure: (input) =>
    set((state) => {
      const next: DownloadFailure = {
        ...input,
        failedAt: Date.now(),
      }
      const filtered = state.failures.filter((f) => f.bookId !== input.bookId)
      return { failures: [...filtered, next] }
    }),
  clearFailure: (bookId) =>
    set((state) => ({
      failures: state.failures.filter((f) => f.bookId !== bookId),
    })),
  clear: () => set({ failures: [] }),
}))

/**
 * Convenience accessor for non-React callers (sync engine, status indicator
 * diagnostics) that just need a snapshot of the current failed-download list.
 */
export function getFailedDownloads(): DownloadFailure[] {
  return useDownloadErrorStore.getState().failures
}
