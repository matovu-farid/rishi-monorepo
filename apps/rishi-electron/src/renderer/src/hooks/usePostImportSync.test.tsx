import { describe, it, expect, beforeEach, vi } from 'vitest'
import { renderHook } from '@testing-library/react'

// vi.mock factories are hoisted above imports, so any state they reference
// must also be hoisted (`vi.hoisted`). The listenerRef.current ref lives in the
// hoisted block so the mock factory and the tests both see the same closure.
const { triggerWrite, toastError, listenerRef } = vi.hoisted(() => ({
  triggerWrite: vi.fn(),
  toastError: vi.fn(),
  listenerRef: {
    current: undefined as
      | ((event: {
          kind: string
          filePath?: string
          bookId?: number
          format?: string
          error?: string
        }) => void)
      | undefined
  }
}))

vi.mock('@/services', () => ({
  getBookImportService: () => ({
    onImportProgress: (listener: typeof listenerRef.current) => {
      listenerRef.current = listener
      return () => {
        listenerRef.current = undefined
      }
    }
  }),
  getSyncService: () => ({ triggerWrite })
}))

vi.mock('sonner', () => ({
  toast: { error: toastError }
}))

import { usePostImportSync } from './usePostImportSync'

describe('usePostImportSync', () => {
  beforeEach(() => {
    triggerWrite.mockClear()
    toastError.mockClear()
    listenerRef.current = undefined
  })

  it('calls SyncService.triggerWrite() on a `done` event', () => {
    renderHook(() => usePostImportSync())
    expect(listenerRef.current).toBeDefined()

    listenerRef.current?.({ kind: 'done', filePath: '/x.epub', bookId: 1, format: 'epub' })

    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('does NOT call triggerWrite() on non-done events', () => {
    renderHook(() => usePostImportSync())
    listenerRef.current?.({ kind: 'copying', filePath: '/x.epub' })
    listenerRef.current?.({ kind: 'parsing', filePath: '/x.epub', format: 'epub' })
    expect(triggerWrite).not.toHaveBeenCalled()
  })

  it('shows a toast on `upload-failed` with the error message as description', () => {
    renderHook(() => usePostImportSync())
    listenerRef.current?.({
      kind: 'upload-failed',
      filePath: '/big.pdf',
      bookId: 42,
      error: 'Cloud storage is full (9.5 GB used). Limit is 10.0 GB.'
    })
    expect(toastError).toHaveBeenCalledTimes(1)
    expect(toastError).toHaveBeenCalledWith(
      'Sync upload failed',
      expect.objectContaining({
        description: 'Cloud storage is full (9.5 GB used). Limit is 10.0 GB.'
      })
    )
  })

  it('does not blow up if triggerWrite throws', () => {
    renderHook(() => usePostImportSync())
    triggerWrite.mockImplementationOnce(() => {
      throw new Error('sync not started')
    })
    expect(() =>
      listenerRef.current?.({ kind: 'done', filePath: '/x.epub', bookId: 2, format: 'epub' })
    ).not.toThrow()
  })

  it('unsubscribes on unmount', () => {
    const { unmount } = renderHook(() => usePostImportSync())
    expect(listenerRef.current).toBeDefined()
    unmount()
    expect(listenerRef.current).toBeUndefined()
  })
})
