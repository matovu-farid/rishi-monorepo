/**
 * Tests for `lib/sync/upload-error-store.ts`.
 *
 * The store is the bridge between the background book-import upload pipeline
 * and the global UploadErrorSnackbar mounted in the tabs layout. The book
 * import adapter is a non-React caller, so the contract is: call `show(err)`
 * with a typed UploadLimitError-shaped payload, the store formats a message,
 * and any subscriber gets the new `current` slot.
 */

import {
  useUploadErrorStore,
  formatUploadLimitMessage,
} from '@/lib/sync/upload-error-store'

describe('formatUploadLimitMessage', () => {
  it('formats FILE_TOO_LARGE with the limit in MB', () => {
    const msg = formatUploadLimitMessage({
      code: 'FILE_TOO_LARGE',
      limit: 800 * 1024 * 1024,
    })
    expect(msg).toMatch(/800 MB/)
    expect(msg).toMatch(/larger than/)
  })

  it('formats BOOK_LIMIT_REACHED with the count', () => {
    const msg = formatUploadLimitMessage({
      code: 'BOOK_LIMIT_REACHED',
      limit: 500,
    })
    expect(msg).toMatch(/500-book/)
  })

  it('formats STORAGE_LIMIT_REACHED with GB', () => {
    const msg = formatUploadLimitMessage({
      code: 'STORAGE_LIMIT_REACHED',
      limit: 10 * 1024 * 1024 * 1024,
    })
    expect(msg).toMatch(/10 GB/)
    expect(msg.toLowerCase()).toMatch(/full|exceed/)
  })
})

describe('useUploadErrorStore', () => {
  beforeEach(() => {
    useUploadErrorStore.getState().dismiss()
  })

  it('starts with no current notice', () => {
    expect(useUploadErrorStore.getState().current).toBeNull()
  })

  it('captures a FILE_TOO_LARGE error', () => {
    useUploadErrorStore.getState().show({
      code: 'FILE_TOO_LARGE',
      limit: 800 * 1024 * 1024,
    })
    const current = useUploadErrorStore.getState().current
    expect(current).not.toBeNull()
    expect(current?.code).toBe('FILE_TOO_LARGE')
    expect(current?.message).toMatch(/800 MB/)
  })

  it('dismiss clears the current notice', () => {
    useUploadErrorStore.getState().show({
      code: 'STORAGE_LIMIT_REACHED',
      limit: 10 * 1024 * 1024 * 1024,
    })
    expect(useUploadErrorStore.getState().current).not.toBeNull()
    useUploadErrorStore.getState().dismiss()
    expect(useUploadErrorStore.getState().current).toBeNull()
  })

  it('successive show() calls replace the current notice with a new id', () => {
    useUploadErrorStore.getState().show({
      code: 'FILE_TOO_LARGE',
      limit: 100 * 1024 * 1024,
    })
    const firstId = useUploadErrorStore.getState().current?.id
    useUploadErrorStore.getState().show({
      code: 'BOOK_LIMIT_REACHED',
      limit: 500,
    })
    const secondId = useUploadErrorStore.getState().current?.id
    expect(secondId).not.toBe(firstId)
    expect(useUploadErrorStore.getState().current?.code).toBe('BOOK_LIMIT_REACHED')
  })
})
