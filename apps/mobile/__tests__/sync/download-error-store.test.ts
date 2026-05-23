/**
 * Tests for `lib/sync/download-error-store.ts`.
 *
 * The store surfaces *post-fetch* failures (i.e. presigned-URL fetch
 * succeeded, bytes arrived, but the atomic `tmpFile.move()` into the final
 * destination failed). Background callers (sync engine, `getBookForReading`)
 * push a failed download into the store so:
 *
 *  - the sync engine can report a "failed-download list" to UI for retry
 *  - the SyncStatusIndicator long-press diagnostics include redownload-
 *    pending books
 *  - any screen that can present a retry button (library, reader error
 *    overlay) can subscribe and re-issue `downloadBookFile`
 *
 * The store deliberately does NOT trigger the retry itself — it only tracks
 * state — so the test asserts state transitions, not network behavior.
 */

import {
  useDownloadErrorStore,
  getFailedDownloads,
} from '@/lib/sync/download-error-store'

describe('download-error-store', () => {
  beforeEach(() => {
    useDownloadErrorStore.getState().clear()
  })

  it('starts with an empty failed-downloads list', () => {
    expect(getFailedDownloads()).toEqual([])
  })

  it('records a failed download with bookId, r2Key, format, and reason', () => {
    useDownloadErrorStore.getState().recordFailure({
      bookId: 'b1',
      r2Key: 'r2/epub/hash1',
      format: 'epub',
      reason: 'EBUSY: device busy, rename',
    })

    const failures = getFailedDownloads()
    expect(failures).toHaveLength(1)
    expect(failures[0]).toMatchObject({
      bookId: 'b1',
      r2Key: 'r2/epub/hash1',
      format: 'epub',
      reason: 'EBUSY: device busy, rename',
    })
    // Timestamp surfaces so UI can render "X minutes ago".
    expect(typeof failures[0].failedAt).toBe('number')
  })

  it('deduplicates by bookId — re-recording updates the existing entry', () => {
    const store = useDownloadErrorStore.getState()
    store.recordFailure({
      bookId: 'b1',
      r2Key: 'r2/epub/hash1',
      format: 'epub',
      reason: 'first error',
    })
    store.recordFailure({
      bookId: 'b1',
      r2Key: 'r2/epub/hash1',
      format: 'epub',
      reason: 'second error',
    })

    const failures = getFailedDownloads()
    expect(failures).toHaveLength(1)
    expect(failures[0].reason).toBe('second error')
  })

  it('clearFailure removes a single bookId without affecting others', () => {
    const store = useDownloadErrorStore.getState()
    store.recordFailure({
      bookId: 'b1',
      r2Key: 'k1',
      format: 'epub',
      reason: 'r1',
    })
    store.recordFailure({
      bookId: 'b2',
      r2Key: 'k2',
      format: 'pdf',
      reason: 'r2',
    })

    store.clearFailure('b1')

    const failures = getFailedDownloads()
    expect(failures.map((f) => f.bookId)).toEqual(['b2'])
  })

  it('clear() empties the entire list', () => {
    const store = useDownloadErrorStore.getState()
    store.recordFailure({ bookId: 'b1', r2Key: 'k1', format: 'epub', reason: 'x' })
    store.recordFailure({ bookId: 'b2', r2Key: 'k2', format: 'pdf', reason: 'y' })

    store.clear()

    expect(getFailedDownloads()).toEqual([])
  })

  it('subscribers see updates when a failure is recorded', () => {
    const seen: number[] = []
    const unsubscribe = useDownloadErrorStore.subscribe((state) => {
      seen.push(state.failures.length)
    })

    useDownloadErrorStore.getState().recordFailure({
      bookId: 'b1',
      r2Key: 'k1',
      format: 'epub',
      reason: 'x',
    })

    expect(seen[seen.length - 1]).toBe(1)
    unsubscribe()
  })
})
