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
})
