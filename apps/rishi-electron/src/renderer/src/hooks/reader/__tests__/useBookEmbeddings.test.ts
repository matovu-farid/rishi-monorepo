import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import type { PageDataInsertable } from '@/services'

// Wave 3 will create src/renderer/src/hooks/reader/useBookEmbeddings.ts.
const HOOK_PATH = '@/hooks/' + 'reader/useBookEmbeddings'

// Hoist mock impls so vi.mock factories can reference them — vi.mock is
// hoisted to the top of the file by the transform, ahead of normal const
// declarations.
const mocks = vi.hoisted(() => ({
  hasIndexedBookData: vi.fn<(params: { bookId: number }) => Promise<boolean>>(),
  indexBook: vi.fn<(bookId: number, pageData: PageDataInsertable[]) => Promise<void>>()
}))

vi.mock('@/lib/api', async () => {
  // Preserve the rest of @/lib/api so other test setup isn't disturbed.
  const actual = await vi.importActual<typeof import('@/lib/api')>('@/lib/api')
  return {
    ...actual,
    hasIndexedBookData: mocks.hasIndexedBookData
  }
})

vi.mock('@/services', async () => {
  const actual = await vi.importActual<typeof import('@/services')>('@/services')
  return {
    ...actual,
    getBookImportService: () => ({
      indexBook: mocks.indexBook
    })
  }
})

type BuildPageData = () => Promise<PageDataInsertable[]>

type UseBookEmbeddings = (params: {
  bookId: number
  ready: boolean
  buildPageData: BuildPageData
}) => void

async function loadHook(): Promise<UseBookEmbeddings> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useBookEmbeddings: UseBookEmbeddings
  }
  return mod.useBookEmbeddings
}

beforeEach(() => {
  mocks.hasIndexedBookData.mockReset()
  mocks.indexBook.mockReset()
})

describe('useBookEmbeddings', () => {
  it('is a noop when ready is false', async () => {
    const useBookEmbeddings = await loadHook()
    const buildPageData = vi.fn<BuildPageData>().mockResolvedValue([])
    renderHook(() => useBookEmbeddings({ bookId: 7, ready: false, buildPageData }))
    // Give microtasks a chance to flush in case the hook scheduled work.
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 0)
    })
    expect(mocks.hasIndexedBookData).not.toHaveBeenCalled()
    expect(mocks.indexBook).not.toHaveBeenCalled()
    expect(buildPageData).not.toHaveBeenCalled()
  })

  it('uses hasIndexedBookData (not hasSavedEpubData) to check existing index', async () => {
    const useBookEmbeddings = await loadHook()
    mocks.hasIndexedBookData.mockResolvedValue(true)
    const buildPageData = vi.fn<BuildPageData>().mockResolvedValue([])
    renderHook(() => useBookEmbeddings({ bookId: 7, ready: true, buildPageData }))
    await waitFor(() => {
      expect(mocks.hasIndexedBookData).toHaveBeenCalledWith({ bookId: 7 })
    })
  })

  it('skips indexBook and buildPageData when already indexed', async () => {
    const useBookEmbeddings = await loadHook()
    mocks.hasIndexedBookData.mockResolvedValue(true)
    const buildPageData = vi.fn<BuildPageData>().mockResolvedValue([])
    renderHook(() => useBookEmbeddings({ bookId: 7, ready: true, buildPageData }))
    await waitFor(() => {
      expect(mocks.hasIndexedBookData).toHaveBeenCalled()
    })
    // Give any pending then-chains a tick to flush.
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 0)
    })
    expect(buildPageData).not.toHaveBeenCalled()
    expect(mocks.indexBook).not.toHaveBeenCalled()
  })

  it('calls buildPageData and feeds its result to indexBook when not indexed', async () => {
    const useBookEmbeddings = await loadHook()
    mocks.hasIndexedBookData.mockResolvedValue(false)
    const pageData: PageDataInsertable[] = [
      { id: 1, pageNumber: 1, bookId: 7, data: 'page one' },
      { id: 2, pageNumber: 2, bookId: 7, data: 'page two' }
    ]
    const buildPageData = vi.fn<BuildPageData>().mockResolvedValue(pageData)
    renderHook(() => useBookEmbeddings({ bookId: 7, ready: true, buildPageData }))
    await waitFor(() => {
      expect(mocks.indexBook).toHaveBeenCalledWith(7, pageData)
    })
    expect(buildPageData).toHaveBeenCalledTimes(1)
  })

  it('embeddingsProcessedRef guard prevents a second run on re-render', async () => {
    const useBookEmbeddings = await loadHook()
    mocks.hasIndexedBookData.mockResolvedValue(false)
    const buildPageData = vi
      .fn<BuildPageData>()
      .mockResolvedValue([{ id: 1, pageNumber: 1, bookId: 7, data: 'x' }])
    const { rerender } = renderHook(
      ({ chapterCount }: { chapterCount: number }) => {
        // chapterCount is included in the closure so re-renders look like
        // the production view component (where chapter count changes during
        // load). The hook should still only run once.
        void chapterCount
        return useBookEmbeddings({ bookId: 7, ready: true, buildPageData })
      },
      { initialProps: { chapterCount: 1 } }
    )
    await waitFor(() => {
      expect(mocks.indexBook).toHaveBeenCalledTimes(1)
    })
    rerender({ chapterCount: 5 })
    rerender({ chapterCount: 10 })
    // Allow microtasks from any spurious re-entry.
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 10)
    })
    expect(buildPageData).toHaveBeenCalledTimes(1)
    expect(mocks.indexBook).toHaveBeenCalledTimes(1)
  })
})
