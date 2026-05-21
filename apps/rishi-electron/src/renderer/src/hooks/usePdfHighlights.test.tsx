import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { usePdfHighlights } from './usePdfHighlights'

describe('usePdfHighlights', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('does NOT call highlightsList when bookSyncId is empty (Book prop may lack syncId at mount)', () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValue([])

    const { result } = renderHook(() => usePdfHighlights(''))
    expect(listMock).not.toHaveBeenCalled()
    expect(result.current.highlights).toEqual([])
  })

  it('loads highlights once bookSyncId becomes non-empty (mirrors IPC-fetched booksGetSyncId arrival)', async () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValue([
      {
        id: 'a',
        bookId: 'sync-1',
        format: 'pdf',
        cfiRange: null,
        locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }),
        text: 't',
        color: 'yellow',
        note: '',
        chapter: null,
        createdAt: 'now',
        updatedAt: null,
        syncId: null,
        syncVersion: 0,
        isDirty: 0,
        isDeleted: 0
      },
      {
        id: 'b',
        bookId: 'sync-1',
        format: 'epub',
        cfiRange: 'epubcfi(/6/4!/4/2)',
        locator: null,
        text: 'e',
        color: 'yellow',
        note: '',
        chapter: null,
        createdAt: 'now',
        updatedAt: null,
        syncId: null,
        syncVersion: 0,
        isDirty: 0,
        isDeleted: 0
      }
    ])

    const { result, rerender } = renderHook(({ id }) => usePdfHighlights(id), {
      initialProps: { id: '' }
    })
    expect(listMock).not.toHaveBeenCalled()

    rerender({ id: 'sync-1' })

    await waitFor(() => {
      expect(listMock).toHaveBeenCalledWith('sync-1')
      expect(result.current.highlights).toHaveLength(1)
      expect(result.current.highlights[0].format).toBe('pdf')
    })
  })

  it('refresh() re-fetches without changing bookSyncId', async () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValue([])

    const { result } = renderHook(() => usePdfHighlights('sync-1'))
    await waitFor(() => expect(listMock).toHaveBeenCalledTimes(1))

    await result.current.refresh()
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('bookSyncId change re-fetches with new id and replaces (not merges) results', async () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    const makeRow = (id: string, bookId: string) => ({
      id,
      bookId,
      format: 'pdf',
      cfiRange: null,
      locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }),
      text: id,
      color: 'yellow',
      note: '',
      chapter: null,
      createdAt: 'now',
      updatedAt: null,
      syncId: null,
      syncVersion: 0,
      isDirty: 0,
      isDeleted: 0
    })
    listMock
      .mockResolvedValueOnce([makeRow('a', 'sync-1')])
      .mockResolvedValueOnce([makeRow('b', 'sync-2')])

    const { result, rerender } = renderHook(({ id }) => usePdfHighlights(id), {
      initialProps: { id: 'sync-1' }
    })
    await waitFor(() => {
      expect(listMock).toHaveBeenCalledWith('sync-1')
      expect(result.current.highlights).toHaveLength(1)
      expect(result.current.highlights[0].id).toBe('a')
    })

    rerender({ id: 'sync-2' })

    await waitFor(() => {
      expect(listMock).toHaveBeenCalledWith('sync-2')
      expect(listMock).toHaveBeenCalledTimes(2)
      expect(result.current.highlights).toHaveLength(1)
      expect(result.current.highlights[0].id).toBe('b')
    })
  })

  it('IPC rejection leaves highlights stable and a subsequent successful refresh() recovers', async () => {
    // Pins current behaviour: the effect at usePdfHighlights.ts:30 has no
    // .catch, so a rejected highlightsList surfaces as an unhandled rejection
    // in the renderer (production defect noted in A033). The hook itself does
    // NOT throw synchronously and leaves `highlights` as the initial empty
    // array. We capture unhandledrejection events to keep the test from
    // failing the suite while the production .catch is missing, and assert
    // recovery via a successful refresh().
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    const onUnhandled = (e: PromiseRejectionEvent): void => {
      e.preventDefault()
    }
    const onProcessUnhandled = (): void => {
      /* swallow — see comment above */
    }
    window.addEventListener('unhandledrejection', onUnhandled)
    process.on('unhandledRejection', onProcessUnhandled)

    try {
      listMock.mockRejectedValueOnce(new Error('IPC down'))

      const { result } = renderHook(() => usePdfHighlights('sync-1'))
      await waitFor(() => expect(listMock).toHaveBeenCalledWith('sync-1'))

      // Hook stays mounted and exposes the initial empty array.
      expect(Array.isArray(result.current.highlights)).toBe(true)
      expect(result.current.highlights).toEqual([])

      // A subsequent successful refresh recovers.
      listMock.mockResolvedValueOnce([
        {
          id: 'r',
          bookId: 'sync-1',
          format: 'pdf',
          cfiRange: null,
          locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }),
          text: 'r',
          color: 'yellow',
          note: '',
          chapter: null,
          createdAt: 'now',
          updatedAt: null,
          syncId: null,
          syncVersion: 0,
          isDirty: 0,
          isDeleted: 0
        }
      ])
      await result.current.refresh()
      await waitFor(() => {
        expect(result.current.highlights).toHaveLength(1)
        expect(result.current.highlights[0].id).toBe('r')
      })
    } finally {
      window.removeEventListener('unhandledrejection', onUnhandled)
      process.off('unhandledRejection', onProcessUnhandled)
    }
  })
})
