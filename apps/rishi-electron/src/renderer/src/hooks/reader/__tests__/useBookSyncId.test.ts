import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { RefObject } from 'react'
import { renderHook, waitFor } from '@testing-library/react'

// Intercept publishBookmarksToMenu so we can assert it was called once the
// sync id resolves. The bookmark-storage module also exports other helpers
// the hook should NOT call, so stub the whole module surface defensively.
const publishBookmarksToMenu = vi.fn(async (_id: string) => undefined)
vi.mock('@/modules/bookmark-storage', () => ({
  publishBookmarksToMenu: (id: string) => publishBookmarksToMenu(id)
}))

// Wave 3 will create src/renderer/src/hooks/reader/useBookSyncId.ts. Until
// then this dynamic import resolves to a module-not-found rejection, which
// is the expected red-phase failure mode.
type BookSyncIdHook = (bookId: number) => {
  bookSyncId: string
  bookSyncIdRef: RefObject<string | null>
}

// Build the specifier from parts so vite's import-analysis can't statically
// resolve it at transform time — the hook file is created in Wave 3.
const HOOK_PATH = '@/hooks/' + 'reader/useBookSyncId'

async function loadHook(): Promise<BookSyncIdHook> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useBookSyncId: BookSyncIdHook
  }
  return mod.useBookSyncId
}

const electron = (): { booksGetSyncId: ReturnType<typeof vi.fn> } =>
  (window as unknown as { electron: { booksGetSyncId: ReturnType<typeof vi.fn> } }).electron

beforeEach(() => {
  publishBookmarksToMenu.mockClear()
  electron().booksGetSyncId.mockReset()
})

describe('useBookSyncId', () => {
  it('calls window.electron.booksGetSyncId(bookId) on mount', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-123')
    const useBookSyncId = await loadHook()
    renderHook(() => useBookSyncId(42))
    expect(electron().booksGetSyncId).toHaveBeenCalledWith(42)
  })

  it('exposes the resolved sync id via state and ref', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-abc')
    const useBookSyncId = await loadHook()
    const { result } = renderHook(() => useBookSyncId(7))
    await waitFor(() => {
      expect(result.current.bookSyncId).toBe('sync-abc')
    })
    expect(result.current.bookSyncIdRef.current).toBe('sync-abc')
  })

  it('publishes bookmarks to the menu once the sync id is non-empty', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-xyz')
    const useBookSyncId = await loadHook()
    renderHook(() => useBookSyncId(11))
    await waitFor(() => {
      expect(publishBookmarksToMenu).toHaveBeenCalledWith('sync-xyz')
    })
    expect(publishBookmarksToMenu).toHaveBeenCalledTimes(1)
  })

  it('does not publish bookmarks when the sync id is null/empty', async () => {
    electron().booksGetSyncId.mockResolvedValue(null)
    const electronApi = window.electron as unknown as {
      getBook: ReturnType<typeof vi.fn>
      saveBook: ReturnType<typeof vi.fn>
    }
    // Block the generate-and-persist fallback so this case stays null.
    electronApi.getBook.mockResolvedValueOnce(null)
    const useBookSyncId = await loadHook()
    const { result } = renderHook(() => useBookSyncId(99))
    // Wait on a positive signal (the resolve of booksGetSyncId) instead of a
    // bare setTimeout(0) — the negative assertion below is only meaningful
    // once the hook has had a real chance to observe the null result.
    await waitFor(() => {
      expect(electron().booksGetSyncId).toHaveBeenCalledWith(99)
      expect(electronApi.getBook).toHaveBeenCalledWith(99)
    })
    expect(publishBookmarksToMenu).not.toHaveBeenCalled()
    expect(result.current.bookSyncId).toBe('')
  })

  it('re-fetches and re-publishes when bookId changes between renders', async () => {
    electron().booksGetSyncId.mockResolvedValueOnce('sync-first')
    electron().booksGetSyncId.mockResolvedValueOnce('sync-second')
    const useBookSyncId = await loadHook()
    const { result, rerender } = renderHook(({ id }: { id: number }) => useBookSyncId(id), {
      initialProps: { id: 1 }
    })

    await waitFor(() => {
      expect(result.current.bookSyncId).toBe('sync-first')
    })
    expect(publishBookmarksToMenu).toHaveBeenCalledWith('sync-first')

    rerender({ id: 2 })

    await waitFor(() => {
      expect(result.current.bookSyncId).toBe('sync-second')
    })
    expect(electron().booksGetSyncId).toHaveBeenCalledWith(2)
    expect(publishBookmarksToMenu).toHaveBeenCalledWith('sync-second')
  })

  // B001: freshly imported books (AZW3/MOBI/EPUB) may have syncId === null at
  // mount time. Before the fix, the ref was cached as null forever and every
  // bookmark handler short-circuited. The hook must mirror useChat.ts: when
  // the initial fetch returns null, generate a UUID, persist it via saveBook,
  // and expose the resolved value to callers.
  it('generates and persists a syncId when the initial fetch returns null', async () => {
    electron().booksGetSyncId.mockResolvedValue(null)
    const electronApi = window.electron as unknown as {
      getBook: ReturnType<typeof vi.fn>
      saveBook: ReturnType<typeof vi.fn>
    }
    const fakeBook = { id: 55, title: 't', author: 'a', filepath: '/x', isDirty: 0 }
    electronApi.getBook.mockResolvedValue(fakeBook)
    electronApi.saveBook.mockResolvedValue({ id: 55 })

    const useBookSyncId = await loadHook()
    const { result } = renderHook(() => useBookSyncId(55))

    await waitFor(() => {
      expect(result.current.bookSyncId).not.toBe('')
    })
    expect(result.current.bookSyncIdRef.current).toBe(result.current.bookSyncId)
    expect(electronApi.saveBook).toHaveBeenCalledWith(
      expect.objectContaining({ id: 55, syncId: result.current.bookSyncId, isDirty: 1 })
    )
  })
})
